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
  alias Archdo.Compiled.{Graph, Query}

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
  def system_diagram(graph) do
    modules = Graph.modules(graph)
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
      end
    end)
  end

  defp classify_module(mod, info) do
    mod_str = Atom.to_string(mod)

    cond do
      # Interface layer: controllers, LiveView, channels, plugs, CLI
      String.contains?(mod_str, "Controller") ->
        :interface

      String.contains?(mod_str, "Live.") ->
        :interface

      String.contains?(mod_str, "LiveView") ->
        :interface

      String.contains?(mod_str, "Channel") ->
        :interface

      String.contains?(mod_str, "Socket") ->
        :interface

      String.contains?(mod_str, "Endpoint") ->
        :interface

      String.contains?(mod_str, "Router") ->
        :interface

      String.contains?(mod_str, "Plug.") ->
        :interface

      String.contains?(mod_str, "Mix.Tasks.") ->
        :interface

      # Infrastructure: Repo, Mailer, HTTP clients, external service adapters
      String.contains?(mod_str, ".Repo") ->
        :infrastructure

      String.contains?(mod_str, "Mailer") ->
        :infrastructure

      String.contains?(mod_str, ".Adapter") ->
        :infrastructure

      String.contains?(mod_str, ".Client") ->
        :infrastructure

      # Check if it's an OTP process (GenServer/Supervisor/Agent)
      Enum.any?(info.behaviours, &(&1 in [Supervisor, GenServer, Agent, :gen_statem])) ->
        :domain

      # Default: domain
      true ->
        :domain
    end
  end

  # --- State machine extraction ---

  defp extract_state_machines(graph) do
    modules = Graph.modules(graph)
    beam_dir = Graph.beam_dir(graph)
    do_extract_state_machines(modules, beam_dir)
  end

  defp do_extract_state_machines(modules, beam_dir) when is_binary(beam_dir) do
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

  defp do_extract_state_machines(_modules, _beam_dir), do: %{}

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
    |> Enum.flat_map(&transitions_for_fn/1)
    |> Enum.uniq()
  end

  defp transitions_for_fn(fn_info), do: Enum.flat_map(fn_info.clauses, &transition_for_clause/1)

  defp transition_for_clause(clause) do
    from_state = clause_from_state(clause.patterns)
    to_state = clause_to_state(clause.return_shape, from_state)
    transition_pair(from_state, to_state)
  end

  defp clause_from_state([{:atom, _, state} | _]) when is_atom(state), do: state
  defp clause_from_state(_), do: nil

  defp clause_to_state({:tagged_tuple, :next_state}, _from), do: :unknown
  defp clause_to_state({:atom, state}, from) when state != from, do: state
  defp clause_to_state(_, _from), do: nil

  defp transition_pair(nil, _to), do: []
  defp transition_pair(_from, nil), do: []
  defp transition_pair(from, to), do: [{from, to}]

  # --- Inside tools detection ---

  @repo_fns [:get, :get!, :all, :insert, :update, :delete, :one, :transaction]
  @file_fns [:read, :read!, :write, :write!, :ls, :mkdir_p]

  defp detect_inside_tools(_modules, graph) do
    Graph.calls(graph)
    |> Enum.reduce(MapSet.new(), fn call, acc ->
      callee_mod = elem(call.callee, 0)
      callee_fn = elem(call.callee, 1)

      case classify_tool_call(callee_mod, Atom.to_string(callee_mod), callee_fn) do
        nil -> acc
        tag -> MapSet.put(acc, tag)
      end
    end)
    |> MapSet.to_list()
  end

  defp classify_tool_call(_mod, mod_str, fn_atom)
       when fn_atom in @repo_fns do
    case String.contains?(mod_str, "Repo") do
      true -> :database
      false -> tool_by_module_string(mod_str)
    end
  end

  defp classify_tool_call(:ets, _mod_str, _fn), do: :ets
  defp classify_tool_call(File, _mod_str, fn_atom) when fn_atom in @file_fns, do: :file_system
  defp classify_tool_call(_mod, mod_str, _fn), do: tool_by_module_string(mod_str)

  defp tool_by_module_string(mod_str) do
    cond do
      mod_str =~ "PubSub" -> :pubsub
      mod_str =~ ~r/(Req|HTTPoison|Finch|Tesla)/ -> :http_client
      mod_str =~ ~r/(Mailer|Swoosh|Bamboo)/ -> :mailer
      mod_str =~ ~r/(Cachex|ConCache)/ -> :cache
      true -> nil
    end
  end

  # --- Outside connection detection ---

  defp detect_outside_connections(modules) do
    mod_strings =
      modules
      |> Map.keys()
      |> Enum.map(&Atom.to_string/1)

    [:http, :websocket, :liveview, :cli, :api]
    |> Enum.filter(&Enum.any?(mod_strings, fn s -> outside_signal?(&1, s) end))
  end

  defp outside_signal?(:http, mod_str), do: String.contains?(mod_str, "Endpoint")
  defp outside_signal?(:websocket, mod_str), do: String.contains?(mod_str, "Channel")

  defp outside_signal?(:liveview, mod_str),
    do: String.contains?(mod_str, "Live.") or String.contains?(mod_str, "LiveView")

  defp outside_signal?(:cli, mod_str), do: String.contains?(mod_str, "Mix.Tasks.")

  defp outside_signal?(:api, mod_str),
    do: String.contains?(mod_str, "API") or String.contains?(mod_str, "Api")

  # --- Layout computation ---

  defp compute_layout(outside, layers, tools, state_machines) do
    outside_count = max(length(outside), 1)
    interface_count = min(length(layers.interface), 8)
    domain_count = min(length(layers.domain), 10)
    infra_count = min(length(layers.infrastructure), 6)
    tools_count = max(length(tools), 1)
    sm_count = min(map_size(state_machines), 3)

    max_cols =
      Enum.max([
        outside_count,
        interface_count,
        domain_count + sm_count,
        infra_count,
        tools_count
      ])

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
    {outside_elems, y, _pos0} =
      render_horizontal_layer(
        @margin,
        y,
        w,
        layout.layer_h,
        "Outside World",
        @layer_bg_outside,
        @layer_border_outside,
        render_outside_nodes(outside),
        []
      )

    y = y + @layer_gap

    # Layer 2: Interface — prioritize modules with most connections
    interface_mods = prioritize_by_connections(layers.interface, graph, 8)

    {interface_elems, y, pos_interface} =
      render_horizontal_layer(
        @margin,
        y,
        w,
        layout.layer_h,
        "Interface",
        @layer_bg_interface,
        @layer_border_interface,
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

    domain_nodes =
      render_module_nodes(Enum.reject(all_domain_mods, &(&1 in sm_mods)), @layer_border_domain, 8)

    sm_nodes = render_state_machine_nodes(state_machines)

    {domain_elems, y, pos_domain} =
      render_horizontal_layer(
        @margin,
        y,
        w,
        layout.domain_layer_h,
        "Domain",
        @layer_bg_domain,
        @layer_border_domain,
        domain_nodes ++ sm_nodes,
        all_domain_mods
      )

    y = y + @layer_gap

    # Layer 4: Infrastructure — prioritize connected modules
    infra_mods = prioritize_by_connections(layers.infrastructure, graph, 6)

    {infra_elems, y, pos_infra} =
      render_horizontal_layer(
        @margin,
        y,
        w,
        layout.layer_h,
        "Infrastructure",
        @layer_bg_infra,
        @layer_border_infra,
        render_module_nodes(infra_mods, @layer_border_infra, 6),
        infra_mods
      )

    y = y + @layer_gap

    # Layer 5: Inside Tools (bottom)
    {tools_elems, _y, _pos_tools} =
      render_horizontal_layer(
        @margin,
        y,
        w,
        layout.layer_h,
        "Inside Tools",
        @layer_bg_tools,
        @layer_border_tools,
        render_tool_nodes(tools),
        []
      )

    # Cross-layer wires between specific modules
    cross_wires =
      render_cross_layer_wires(graph, [
        {pos_interface, pos_domain, @layer_border_interface},
        {pos_domain, pos_infra, @layer_border_domain}
      ])

    # Title
    title = [
      ~s[<text x="#{@margin}" y="18" fill="#{@text}" font-size="13" font-weight="600" font-family="monospace">System Architecture — #{map_size(Graph.modules(graph))} modules</text>]
    ]

    # Arrowhead def
    arrow_def = [
      ~s[<defs><marker id="arrowhead" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto"><polygon points="0 0, 8 3, 0 6" fill="#{@wire_color}" opacity="0.5"/></marker></defs>]
    ]

    all =
      arrow_def ++
        title ++
        outside_elems ++
        interface_elems ++ domain_elems ++ infra_elems ++ tools_elems ++ cross_wires

    wrap_svg(all, layout.total_w, layout.total_h)
  end

  defp render_horizontal_layer(
         x,
         y,
         width,
         height,
         title,
         bg_color,
         border_color,
         node_renderers,
         modules
       ) do
    frame = [
      ~s[<rect x="#{x}" y="#{y}" width="#{width}" height="#{height}" rx="8" fill="#{bg_color}" stroke="#{border_color}" stroke-width="1.5" opacity="0.6"/>],
      ~s[<text x="#{x + 12}" y="#{y + 17}" fill="#{border_color}" font-size="11" font-weight="600" font-family="monospace">#{title}</text>]
    ]

    # Spread nodes horizontally and track positions
    # Pad modules to match renderers length so zip works
    padded_modules =
      modules ++ List.duplicate(nil, max(0, length(node_renderers) - length(modules)))

    {node_elems, positions} =
      node_renderers
      |> Enum.zip(padded_modules)
      |> Enum.with_index()
      |> Enum.reduce({[], %{}}, fn {{renderer, mod}, idx}, {elems, pos} ->
        nx = x + @layer_padding + idx * (@node_w + @node_gap)
        ny = y + @layer_header + @layer_padding

        new_elems = renderer.(nx, ny)

        center_x = nx + @node_w / 2

        new_pos =
          case mod do
            nil -> pos
            _ -> Map.put(pos, mod, {center_x, ny, ny + @node_h})
          end

        {[new_elems | elems], new_pos}
      end)

    {frame ++ List.flatten(Enum.reverse(node_elems)), y + height, positions}
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
        |> Enum.flat_map(&directed_edges(&1, graph, lower_set))
        |> Enum.uniq()

      # Find calls from lower → upper (return/callback)
      up_connections =
        lower_mods
        |> Enum.flat_map(&directed_edges(&1, graph, upper_set))
        |> Enum.uniq()

      shown_down = Enum.take(down_connections, 5)
      shown_up = Enum.take(up_connections, 3)

      hidden_count =
        length(down_connections) - length(shown_down) + length(up_connections) - length(shown_up)

      # Render downward tunnels (output bottom → input left)
      down_elems =
        shown_down
        |> Enum.with_index()
        |> Enum.flat_map(fn {{upper_mod, lower_mod}, wire_idx} ->
          render_tunnel_wire(
            upper_positions,
            lower_positions,
            upper_mod,
            lower_mod,
            color,
            wire_idx,
            :down
          )
        end)

      # Render upward tunnels (output from lower right → input upper)
      up_elems =
        shown_up
        |> Enum.with_index()
        |> Enum.flat_map(fn {{lower_mod, upper_mod}, wire_idx} ->
          render_tunnel_wire(
            lower_positions,
            upper_positions,
            lower_mod,
            upper_mod,
            @wire_color,
            wire_idx,
            :up
          )
        end)

      badge = hidden_more_badge(hidden_count, upper_positions)

      down_elems ++ up_elems ++ badge
    end)
  end

  defp directed_edges(source_mod, graph, target_set) do
    graph
    |> Query.module_dependencies(source_mod)
    |> Enum.filter(&MapSet.member?(target_set, &1))
    |> Enum.map(fn target_mod -> {source_mod, target_mod} end)
  end

  # §§ elixir-implementing: §2.1 — guard-dispatched on hidden_count.
  defp hidden_more_badge(count, _positions) when count <= 0, do: []
  defp hidden_more_badge(count, positions), do: badge_for_positions(Map.values(positions), count)

  defp badge_for_positions([{_cx, _ty, by} | _], hidden_count) do
    [
      ~s[<text x="#{@margin + 4}" y="#{by + 14}" fill="#{@dim}" font-size="8" font-family="monospace" opacity="0.6">+#{hidden_count} more</text>]
    ]
  end

  defp badge_for_positions(_, _hidden_count), do: []

  defp render_tunnel_wire(
         source_positions,
         target_positions,
         source_mod,
         target_mod,
         color,
         wire_idx,
         direction
       ) do
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
          |> Enum.flat_map(&state_glyph(&1, x, y, length(states)))

        # Render transitions as small arrows between states
        transition_elems =
          sm_info.transitions
          |> Enum.take(4)
          |> Enum.flat_map(&transition_arrow(&1, states, x, y))

        header ++ state_elems ++ transition_elems
      end
    end)
  end

  defp state_glyph({state, idx}, x, y, total) do
    sx = x + 20
    sy = y + 34 + idx * 20
    color = state_color(state, idx, total)

    [
      ~s[<circle cx="#{sx}" cy="#{sy}" r="#{@state_radius / 2}" fill="#{color}" opacity="0.8"/>],
      ~s[<text x="#{sx + 14}" y="#{sy + 4}" fill="#{@text}" font-size="9" font-family="monospace">:#{state}</text>]
    ]
  end

  defp transition_arrow({from, to}, states, x, y) do
    from_idx = Enum.find_index(states, &(&1 == from))
    to_idx = Enum.find_index(states, &(&1 == to))
    transition_arrow_for(from_idx, to_idx, x, y)
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # the missing-index nil case.
  defp transition_arrow_for(nil, _to_idx, _x, _y), do: []
  defp transition_arrow_for(_from_idx, nil, _x, _y), do: []

  defp transition_arrow_for(from_idx, to_idx, x, y) do
    fy = y + 34 + from_idx * 20
    ty = y + 34 + to_idx * 20
    ax = x + @node_w - 20

    [
      ~s[<path d="M #{ax - 10} #{fy} C #{ax} #{fy}, #{ax} #{ty}, #{ax - 10} #{ty}" fill="none" stroke="#{@wire_color}" stroke-width="0.8" marker-end="url(#arrowhead)"/>]
    ]
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
      deps = length(Query.module_dependencies(graph, mod))
      dependents = length(Query.module_dependents(graph, mod))
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
