defmodule Archdo.Compiled.DiagramSystem do
  @moduledoc false

  # Generates a full system architecture SVG showing the hexagonal layers:
  #
  #   Outside World → Interface → Domain → Infrastructure → Inside Tools
  #
  # External connections (HTTP, WebSocket, CLI) on the left.
  # Internal tools (Database, Redis, S3, Email) on the right.
  # State machines rendered as embedded state diagrams within their process boxes.
  # OTP processes shown with mailboxes.
  # The whole thing flows left-to-right like a LabVIEW block diagram.

  alias Archdo.AST
  alias Archdo.Compiled.Graph

  # Layout — horizontal layers stacked top to bottom
  # Each layer is a full-width horizontal band.
  # Modules within a layer spread left to right.
  # Connections between layers go vertically (↓↑ bidirectional).
  @layer_gap 32
  @node_w 160
  @node_h 44
  @node_gap 14
  @margin 40
  @layer_header 24
  @layer_padding 10
  @state_radius 14
  # @state_gap 36

  # Colors (Catppuccin Mocha)
  @bg "#1E1E2E"
  @text "#CDD6F4"
  @dim "#6C7086"
  @layer_bg_outside "#1a1520"
  @layer_bg_interface "#1a2030"
  @layer_bg_domain "#1a2a1a"
  @layer_bg_infra "#2a1a1a"
  @layer_bg_tools "#1a1520"
  @layer_border_outside "#9399B2"
  @layer_border_interface "#89B4FA"
  @layer_border_domain "#A6E3A1"
  @layer_border_infra "#FAB387"
  @layer_border_tools "#CBA6F7"
  @wire_color "#585B70"
  @state_idle "#A6E3A1"
  @state_active "#89B4FA"
  @state_error "#F38BA8"
  @state_terminal "#9399B2"

  @doc """
  Generate a full system architecture SVG with hexagonal layers,
  state machines, and external/internal tool connections.
  """
  @spec system_diagram(Graph.t()) :: String.t()
  def system_diagram(%Graph{modules: modules} = graph) do
    # Classify all modules into architectural layers
    layers = classify_into_layers(modules, graph)

    # Detect state machines and extract their states
    state_machines = extract_state_machines(graph)

    # Detect external tools (DB, HTTP clients, etc.)
    tools = detect_inside_tools(modules, graph)

    # Detect outside interfaces
    outside = detect_outside_connections(modules)

    # Calculate layout
    layout = compute_layout(outside, layers, tools, state_machines)

    render_system(layout, layers, state_machines, tools, outside, graph)
  end

  # --- Layer classification ---

  defp classify_into_layers(modules, _graph) do
    Enum.reduce(modules, %{interface: [], domain: [], infrastructure: []}, fn {mod, info}, acc ->
      layer = classify_module(mod, info)

      case layer do
        :interface -> %{acc | interface: [mod | acc.interface]}
        :infrastructure -> %{acc | infrastructure: [mod | acc.infrastructure]}
        :domain -> %{acc | domain: [mod | acc.domain]}
        _ -> acc
      end
    end)
  end

  defp classify_module(mod, info) do
    mod_str = Atom.to_string(mod)

    cond do
      # Interface layer: controllers, LiveView, channels, plugs, CLI
      String.contains?(mod_str, "Controller") -> :interface
      String.contains?(mod_str, "Live.") -> :interface
      String.contains?(mod_str, "LiveView") -> :interface
      String.contains?(mod_str, "Channel") -> :interface
      String.contains?(mod_str, "Socket") -> :interface
      String.contains?(mod_str, "Endpoint") -> :interface
      String.contains?(mod_str, "Router") -> :interface
      String.contains?(mod_str, "Plug.") -> :interface
      String.contains?(mod_str, "Mix.Tasks.") -> :interface

      # Infrastructure: Repo, Mailer, HTTP clients, external service adapters
      String.contains?(mod_str, ".Repo") -> :infrastructure
      String.contains?(mod_str, "Mailer") -> :infrastructure
      String.contains?(mod_str, ".Adapter") -> :infrastructure
      String.contains?(mod_str, ".Client") -> :infrastructure

      # Check if it's an OTP process (GenServer/Supervisor/Agent)
      Enum.any?(info.behaviours, &(&1 in [Supervisor, GenServer, Agent, :gen_statem])) ->
        :domain

      # Default: domain
      true -> :domain
    end
  end

  # --- State machine extraction ---

  defp extract_state_machines(%Graph{modules: modules, beam_dir: beam_dir})
       when is_binary(beam_dir) do
    # Find modules that look like state machines:
    # 1. Modules using gen_statem
    # 2. Modules with multiple clauses dispatching on atom state names
    # 3. Modules returning {:next_state, ...} tuples

    clauses_map = Graph.extract_function_clauses(beam_dir)

    modules
    |> Enum.flat_map(fn {mod, info} ->
      is_gen_statem = :gen_statem in info.behaviours

      fns = Map.get(clauses_map, mod, [])

      # Look for state-dispatching patterns in function clauses
      states = extract_states_from_clauses(fns)

      case is_gen_statem or length(states) >= 3 do
        true ->
          transitions = extract_transitions_from_clauses(fns)
          [{mod, %{states: states, transitions: transitions, is_gen_statem: is_gen_statem}}]

        false ->
          []
      end
    end)
    |> Map.new()
  end

  defp extract_state_machines(_graph), do: %{}

  defp extract_states_from_clauses(fns) do
    # Find functions where the first argument is a literal atom in multiple clauses
    # (state dispatch pattern)
    fns
    |> Enum.flat_map(fn fn_info ->
      case fn_info.clause_count >= 2 do
        true ->
          Enum.flat_map(fn_info.clauses, fn clause ->
            case clause.patterns do
              [{:atom, _, state} | _] when is_atom(state) -> [state]
              _ -> []
            end
          end)

        false ->
          []
      end
    end)
    |> Enum.uniq()
    |> Enum.reject(fn s -> s in [true, false, nil, :ok, :error] end)
  end

  defp extract_transitions_from_clauses(fns) do
    # Look for return values containing {:next_state, atom, ...}
    # or state atoms in return positions that differ from input states
    fns
    |> Enum.flat_map(fn fn_info ->
      Enum.flat_map(fn_info.clauses, fn clause ->
        from_state =
          case clause.patterns do
            [{:atom, _, state} | _] when is_atom(state) -> state
            _ -> nil
          end

        to_state =
          case clause.return_shape do
            {:tagged_tuple, :next_state} -> :unknown
            {:atom, state} when state != from_state -> state
            _ -> nil
          end

        case from_state != nil and to_state != nil do
          true -> [{from_state, to_state}]
          false -> []
        end
      end)
    end)
    |> Enum.uniq()
  end

  # --- Inside tools detection ---

  defp detect_inside_tools(_modules, %Graph{calls: calls}) do
    # Detect calls to known infrastructure modules
    tools = %{
      database: false,
      pubsub: false,
      ets: false,
      http_client: false,
      mailer: false,
      file_system: false,
      cache: false
    }

    Enum.reduce(calls, tools, fn call, acc ->
      callee_mod = elem(call.callee, 0)
      callee_mod_str = Atom.to_string(callee_mod)
      callee_fn = elem(call.callee, 1)

      cond do
        String.contains?(callee_mod_str, "Repo") and callee_fn in [:get, :get!, :all, :insert, :update, :delete, :one, :transaction] ->
          %{acc | database: true}

        callee_mod_str =~ "PubSub" ->
          %{acc | pubsub: true}

        callee_mod == :ets ->
          %{acc | ets: true}

        callee_mod_str =~ ~r/(Req|HTTPoison|Finch|Tesla)/ ->
          %{acc | http_client: true}

        callee_mod_str =~ ~r/(Mailer|Swoosh|Bamboo)/ ->
          %{acc | mailer: true}

        callee_mod == File and callee_fn in [:read, :read!, :write, :write!, :ls, :mkdir_p] ->
          %{acc | file_system: true}

        callee_mod_str =~ ~r/(Cachex|ConCache)/ ->
          %{acc | cache: true}

        true ->
          acc
      end
    end)
    |> Enum.filter(fn {_tool, used} -> used end)
    |> Enum.map(fn {tool, _} -> tool end)
  end

  # --- Outside connection detection ---

  defp detect_outside_connections(modules) do
    mod_strings =
      modules
      |> Map.keys()
      |> Enum.map(&Atom.to_string/1)

    connections = []

    connections =
      case Enum.any?(mod_strings, &String.contains?(&1, "Endpoint")) do
        true -> [:http | connections]
        false -> connections
      end

    connections =
      case Enum.any?(mod_strings, &String.contains?(&1, "Channel")) do
        true -> [:websocket | connections]
        false -> connections
      end

    connections =
      case Enum.any?(mod_strings, &String.contains?(&1, "Live.")) or
             Enum.any?(mod_strings, &String.contains?(&1, "LiveView")) do
        true -> [:liveview | connections]
        false -> connections
      end

    connections =
      case Enum.any?(mod_strings, &String.contains?(&1, "Mix.Tasks.")) do
        true -> [:cli | connections]
        false -> connections
      end

    connections =
      case Enum.any?(mod_strings, &(String.contains?(&1, "API") or String.contains?(&1, "Api"))) do
        true -> [:api | connections]
        false -> connections
      end

    connections
  end

  # --- Layout computation ---

  defp compute_layout(outside, layers, tools, state_machines) do
    outside_count = max(length(outside), 1)
    interface_count = min(length(layers.interface), 8)
    domain_count = min(length(layers.domain), 10)
    infra_count = min(length(layers.infrastructure), 6)
    tools_count = max(length(tools), 1)
    sm_count = min(map_size(state_machines), 3)

    max_cols = Enum.max([outside_count, interface_count, domain_count + sm_count, infra_count, tools_count])

    total_w = max(max_cols * (@node_w + @node_gap) + @margin * 2 + 100, 800)

    # Each layer: header + one row of nodes + padding
    layer_h = @layer_header + @node_h + @layer_padding * 2

    # Domain layer is taller if it has state machines
    domain_layer_h =
      case sm_count > 0 do
        true -> layer_h + 60
        false -> layer_h
      end

    total_h = @margin + 24 + layer_h * 4 + domain_layer_h + @layer_gap * 4 + @margin

    %{
      total_w: total_w,
      total_h: total_h,
      layer_h: layer_h,
      domain_layer_h: domain_layer_h
    }
  end

  # --- Rendering ---

  # Each layer render returns {svg_elements, next_y, positions_map}
  # positions_map: %{module => {center_x, top_y, bottom_y}}

  defp render_system(layout, layers, state_machines, tools, outside, graph) do
    y = @margin + 24
    w = layout.total_w - @margin * 2

    # Layer 1: Outside World (top)
    {outside_elems, y, _pos0} = render_horizontal_layer(
      @margin, y, w, layout.layer_h,
      "Outside World", @layer_bg_outside, @layer_border_outside,
      render_outside_nodes(outside), []
    )
    y = y + @layer_gap

    # Layer 2: Interface — prioritize modules with most connections
    interface_mods = prioritize_by_connections(layers.interface, graph, 8)
    {interface_elems, y, pos_interface} = render_horizontal_layer(
      @margin, y, w, layout.layer_h,
      "Interface", @layer_bg_interface, @layer_border_interface,
      render_module_nodes(interface_mods, @layer_border_interface, 8),
      interface_mods
    )
    y = y + @layer_gap

    # Layer 3: Domain — prioritize connected modules + state machines
    domain_mods = prioritize_by_connections(layers.domain, graph, 8)
    sm_mods = state_machines |> Map.keys() |> Enum.take(3)
    # Ensure state machine modules are included
    all_domain_mods =
      (sm_mods ++ domain_mods)
      |> Enum.uniq()
      |> Enum.take(11)
    domain_nodes = render_module_nodes(Enum.reject(all_domain_mods, &(&1 in sm_mods)), @layer_border_domain, 8)
    sm_nodes = render_state_machine_nodes(state_machines)

    {domain_elems, y, pos_domain} = render_horizontal_layer(
      @margin, y, w, layout.domain_layer_h,
      "Domain", @layer_bg_domain, @layer_border_domain,
      domain_nodes ++ sm_nodes,
      all_domain_mods
    )
    y = y + @layer_gap

    # Layer 4: Infrastructure — prioritize connected modules
    infra_mods = prioritize_by_connections(layers.infrastructure, graph, 6)
    {infra_elems, y, pos_infra} = render_horizontal_layer(
      @margin, y, w, layout.layer_h,
      "Infrastructure", @layer_bg_infra, @layer_border_infra,
      render_module_nodes(infra_mods, @layer_border_infra, 6),
      infra_mods
    )
    y = y + @layer_gap

    # Layer 5: Inside Tools (bottom)
    {tools_elems, _y, _pos_tools} = render_horizontal_layer(
      @margin, y, w, layout.layer_h,
      "Inside Tools", @layer_bg_tools, @layer_border_tools,
      render_tool_nodes(tools), []
    )

    # Cross-layer wires between specific modules
    cross_wires = render_cross_layer_wires(graph, [
      {pos_interface, pos_domain, @layer_border_interface},
      {pos_domain, pos_infra, @layer_border_domain}
    ])

    # Title
    title = [
      ~s[<text x="#{@margin}" y="18" fill="#{@text}" font-size="13" font-weight="600" font-family="monospace">System Architecture — #{map_size(graph.modules)} modules</text>]
    ]

    # Arrowhead def
    arrow_def = [
      ~s[<defs><marker id="arrowhead" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto"><polygon points="0 0, 8 3, 0 6" fill="#{@wire_color}" opacity="0.5"/></marker></defs>]
    ]

    all = arrow_def ++ title ++ outside_elems ++ interface_elems ++ domain_elems ++ infra_elems ++ tools_elems ++ cross_wires
    wrap_svg(all, layout.total_w, layout.total_h)
  end

  defp render_horizontal_layer(x, y, width, height, title, bg_color, border_color, node_renderers, modules) do
    frame = [
      ~s[<rect x="#{x}" y="#{y}" width="#{width}" height="#{height}" rx="8" fill="#{bg_color}" stroke="#{border_color}" stroke-width="1.5" opacity="0.6"/>],
      ~s[<text x="#{x + 12}" y="#{y + 17}" fill="#{border_color}" font-size="11" font-weight="600" font-family="monospace">#{title}</text>]
    ]

    # Spread nodes horizontally and track positions
    {node_elems, positions} =
      node_renderers
      |> Enum.with_index()
      |> Enum.reduce({[], %{}}, fn {renderer, idx}, {elems, pos} ->
        nx = x + @layer_padding + idx * (@node_w + @node_gap)
        ny = y + @layer_header + @layer_padding

        new_elems = renderer.(nx, ny)

        # Track module position for wire routing
        mod =
          case Enum.at(modules, idx) do
            nil -> nil
            m -> m
          end

        center_x = nx + @node_w / 2
        new_pos =
          case mod do
            nil -> pos
            _ -> Map.put(pos, mod, {center_x, ny, ny + @node_h})
          end

        {elems ++ new_elems, new_pos}
      end)

    {frame ++ node_elems, y + height, positions}
  end

  # Tunnel size
  @tunnel_size 8

  defp render_cross_layer_wires(graph, layer_pairs) do
    # LabVIEW-style tunnels:
    # - Output tunnels on the BOTTOM edge of the source layer
    # - Input tunnels on the LEFT edge of the target layer
    # - Orthogonal wire routing: down from output tunnel, then left to input tunnel

    layer_pairs
    |> Enum.with_index()
    |> Enum.flat_map(fn {{upper_positions, lower_positions, color}, _pair_idx} ->
      upper_mods = Map.keys(upper_positions)
      lower_mods = Map.keys(lower_positions)
      lower_set = MapSet.new(lower_mods)
      upper_set = MapSet.new(upper_mods)

      # Find calls from upper → lower
      down_connections =
        upper_mods
        |> Enum.flat_map(fn upper_mod ->
          Graph.module_dependencies(graph, upper_mod)
          |> Enum.filter(&MapSet.member?(lower_set, &1))
          |> Enum.map(fn lower_mod -> {upper_mod, lower_mod} end)
        end)
        |> Enum.uniq()

      # Find calls from lower → upper (return/callback)
      up_connections =
        lower_mods
        |> Enum.flat_map(fn lower_mod ->
          Graph.module_dependencies(graph, lower_mod)
          |> Enum.filter(&MapSet.member?(upper_set, &1))
          |> Enum.map(fn upper_mod -> {lower_mod, upper_mod} end)
        end)
        |> Enum.uniq()

      shown_down = Enum.take(down_connections, 5)
      shown_up = Enum.take(up_connections, 3)
      hidden_count = length(down_connections) - length(shown_down) + length(up_connections) - length(shown_up)

      # Render downward tunnels (output bottom → input left)
      down_elems =
        shown_down
        |> Enum.with_index()
        |> Enum.flat_map(fn {{upper_mod, lower_mod}, wire_idx} ->
          render_tunnel_wire(
            upper_positions, lower_positions,
            upper_mod, lower_mod,
            color, wire_idx, :down
          )
        end)

      # Render upward tunnels (output from lower right → input upper)
      up_elems =
        shown_up
        |> Enum.with_index()
        |> Enum.flat_map(fn {{lower_mod, upper_mod}, wire_idx} ->
          render_tunnel_wire(
            lower_positions, upper_positions,
            lower_mod, upper_mod,
            @wire_color, wire_idx, :up
          )
        end)

      # "+N more" badge
      badge =
        case hidden_count > 0 do
          true ->
            case Enum.at(Map.values(upper_positions), 0) do
              {_cx, _ty, by} ->
                [~s[<text x="#{@margin + 4}" y="#{by + 14}" fill="#{@dim}" font-size="8" font-family="monospace" opacity="0.6">+#{hidden_count} more</text>]]

              _ ->
                []
            end

          false ->
            []
        end

      down_elems ++ up_elems ++ badge
    end)
  end

  defp render_tunnel_wire(source_positions, target_positions, source_mod, target_mod, color, wire_idx, direction) do
    case {Map.get(source_positions, source_mod), Map.get(target_positions, target_mod)} do
      {{src_cx, _src_ty, src_by}, {_tgt_cx, tgt_ty, _tgt_by}} ->
        # Output tunnel: colored square on bottom edge of source module
        out_x = src_cx - @tunnel_size / 2
        out_y = src_by - @tunnel_size / 2

        # Input tunnel: colored square on left edge of target layer
        # Offset vertically by wire_idx to avoid overlap
        in_x = @margin - @tunnel_size
        in_y = tgt_ty + wire_idx * (@tunnel_size + 4)

        # Route point: go down from output tunnel, then left to input tunnel
        route_y =
          case direction do
            :down -> src_by + 8 + wire_idx * 6
            :up -> tgt_ty - 8 - wire_idx * 6
          end

        label = "#{AST.short_name(source_mod)}→#{AST.short_name(target_mod)}"

        [
          # Output tunnel (square on bottom of source)
          ~s[<rect x="#{out_x}" y="#{out_y}" width="#{@tunnel_size}" height="#{@tunnel_size}" rx="1" fill="#{color}" opacity="0.7"/>],

          # Input tunnel (square on left edge of target layer)
          ~s[<rect x="#{in_x}" y="#{in_y}" width="#{@tunnel_size}" height="#{@tunnel_size}" rx="1" fill="#{color}" opacity="0.7"/>],

          # Wire: orthogonal routing — down from output, then left to input
          ~s[<path d="M #{src_cx} #{out_y + @tunnel_size} L #{src_cx} #{route_y} L #{in_x + @tunnel_size} #{route_y} L #{in_x + @tunnel_size} #{in_y + @tunnel_size / 2}" fill="none" stroke="#{color}" stroke-width="1" opacity="0.3"/>],

          # Small label near input tunnel
          ~s[<text x="#{in_x + @tunnel_size + 3}" y="#{in_y + @tunnel_size - 1}" fill="#{color}" font-size="7" font-family="monospace" opacity="0.5">#{label}</text>]
        ]

      _ ->
        []
    end
  end

  defp render_outside_nodes(connections) do
    icons = %{
      http: "🌐",
      websocket: "⚡",
      liveview: "📡",
      cli: "⌨",
      api: "🔌"
    }

    labels = %{
      http: "HTTP / Browser",
      websocket: "WebSocket",
      liveview: "LiveView",
      cli: "CLI / Mix Tasks",
      api: "REST / GraphQL API"
    }

    Enum.map(connections, fn conn ->
      icon = Map.get(icons, conn, "○")
      label = Map.get(labels, conn, to_string(conn))

      fn x, y ->
        [
          ~s[<rect x="#{x}" y="#{y}" width="#{@node_w}" height="#{@node_h}" rx="6" fill="#2D2D3F" stroke="#{@layer_border_outside}" stroke-width="1"/>],
          ~s[<text x="#{x + 12}" y="#{y + 28}" fill="#{@text}" font-size="11" font-family="monospace">#{icon} #{label}</text>]
        ]
      end
    end)
  end

  defp render_module_nodes(module_list, accent_color, max_count) do
    module_list
    |> Enum.take(max_count)
    |> Enum.map(fn mod ->
      name = AST.short_name(mod)

      fn x, y ->
        [
          ~s[<rect x="#{x}" y="#{y}" width="#{@node_w}" height="#{@node_h}" rx="6" fill="#2D2D3F" stroke="#{accent_color}" stroke-width="1"/>],
          ~s[<text x="#{x + 10}" y="#{y + 20}" fill="#{accent_color}" font-size="11" font-weight="500" font-family="monospace">#{name}</text>],
          ~s[<text x="#{x + 10}" y="#{y + 34}" fill="#{@dim}" font-size="8" font-family="monospace">#{AST.module_name(mod)}</text>]
        ]
      end
    end)
  end

  defp render_state_machine_nodes(state_machines) do
    state_machines
    |> Enum.take(3)
    |> Enum.map(fn {mod, sm_info} ->
      name = AST.short_name(mod)
      states = Enum.take(sm_info.states, 5)

      fn x, y ->
        # Taller box for state machine
        sm_h = max(@node_h + length(states) * 20 + 10, @node_h + 30)

        header = [
          ~s[<rect x="#{x}" y="#{y}" width="#{@node_w}" height="#{sm_h}" rx="6" fill="#1D2D1D" stroke="#{@layer_border_domain}" stroke-width="1.5"/>],
          ~s[<text x="#{x + 10}" y="#{y + 18}" fill="#{@layer_border_domain}" font-size="11" font-weight="600" font-family="monospace">◈ #{name}</text>]
        ]

        # Render states as small circles with labels
        state_elems =
          states
          |> Enum.with_index()
          |> Enum.flat_map(fn {state, idx} ->
            sx = x + 20
            sy = y + 34 + idx * 20
            color = state_color(state, idx, length(states))

            [
              ~s[<circle cx="#{sx}" cy="#{sy}" r="#{@state_radius / 2}" fill="#{color}" opacity="0.8"/>],
              ~s[<text x="#{sx + 14}" y="#{sy + 4}" fill="#{@text}" font-size="9" font-family="monospace">:#{state}</text>]
            ]
          end)

        # Render transitions as small arrows between states
        transition_elems =
          sm_info.transitions
          |> Enum.take(4)
          |> Enum.flat_map(fn {from, to} ->
            from_idx = Enum.find_index(states, &(&1 == from))
            to_idx = Enum.find_index(states, &(&1 == to))

            case from_idx != nil and to_idx != nil do
              true ->
                fy = y + 34 + from_idx * 20
                ty = y + 34 + to_idx * 20
                ax = x + @node_w - 20

                [~s[<path d="M #{ax - 10} #{fy} C #{ax} #{fy}, #{ax} #{ty}, #{ax - 10} #{ty}" fill="none" stroke="#{@wire_color}" stroke-width="0.8" marker-end="url(#arrowhead)"/>]]

              false ->
                []
            end
          end)

        header ++ state_elems ++ transition_elems
      end
    end)
  end

  defp render_tool_nodes(tools) do
    icons = %{
      database: "🗄",
      pubsub: "📢",
      ets: "📋",
      http_client: "🌐",
      mailer: "✉",
      file_system: "📁",
      cache: "⚡"
    }

    labels = %{
      database: "PostgreSQL / DB",
      pubsub: "PubSub",
      ets: "ETS Tables",
      http_client: "External APIs",
      mailer: "Email Service",
      file_system: "File System",
      cache: "Cache"
    }

    Enum.map(tools, fn tool ->
      icon = Map.get(icons, tool, "○")
      label = Map.get(labels, tool, to_string(tool))

      fn x, y ->
        [
          ~s[<rect x="#{x}" y="#{y}" width="#{@node_w}" height="#{@node_h}" rx="6" fill="#2D2D3F" stroke="#{@layer_border_tools}" stroke-width="1"/>],
          ~s[<text x="#{x + 12}" y="#{y + 28}" fill="#{@text}" font-size="11" font-family="monospace">#{icon} #{label}</text>]
        ]
      end
    end)
  end

  # Prioritize modules with the most connections (both incoming + outgoing)
  # so the most important modules appear in the diagram
  defp prioritize_by_connections(modules, graph, max) do
    modules
    |> Enum.map(fn mod ->
      deps = length(Graph.module_dependencies(graph, mod))
      dependents = length(Graph.module_dependents(graph, mod))
      {mod, deps + dependents}
    end)
    |> Enum.sort_by(fn {_mod, score} -> score end, :desc)
    |> Enum.take(max)
    |> Enum.map(fn {mod, _score} -> mod end)
  end

  defp state_color(_state, 0, _total), do: @state_idle
  defp state_color(_state, idx, total) when idx == total - 1, do: @state_terminal
  defp state_color(:error, _idx, _total), do: @state_error
  defp state_color(:failed, _idx, _total), do: @state_error
  defp state_color(_state, _idx, _total), do: @state_active

  # --- Helpers ---

  defp wrap_svg(elements, width, height) do
    header = [
      ~s[<?xml version="1.0" encoding="UTF-8"?>],
      ~s[<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{ceil(width)} #{ceil(height)}" width="#{ceil(width)}" height="#{ceil(height)}">],
      ~s[<rect width="100%" height="100%" fill="#{@bg}"/>],
      ~s[<style>text { user-select: none; }</style>]
    ]

    footer = ["</svg>"]
    Enum.join(header ++ elements ++ footer, "\n")
  end
end
