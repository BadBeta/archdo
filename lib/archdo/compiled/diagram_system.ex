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

  alias Archdo.Compiled.Graph

  # Layout
  @layer_gap 40
  @node_w 170
  @node_h 44
  @node_gap 12
  @margin 40
  @layer_header 28
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
    modules
    |> Enum.reduce(%{interface: [], domain: [], infrastructure: []}, fn {mod, info}, acc ->
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
          fn_info.clauses
          |> Enum.flat_map(fn clause ->
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
      fn_info.clauses
      |> Enum.flat_map(fn clause ->
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
    sm_count = map_size(state_machines)

    max_rows = Enum.max([outside_count, interface_count, domain_count + sm_count, infra_count, tools_count])

    layer_h = max_rows * (@node_h + @node_gap) + @layer_header + @margin

    %{
      layer_h: layer_h,
      total_w: @margin * 2 + 5 * @node_w + 4 * @layer_gap,
      total_h: layer_h + @margin * 2 + 20
    }
  end

  # --- Rendering ---

  defp render_system(layout, layers, state_machines, tools, outside, graph) do
    x = @margin

    # Layer 1: Outside World
    {outside_elems, x} = render_layer(
      x, @margin + 20, layout.layer_h,
      "Outside World", @layer_bg_outside, @layer_border_outside,
      render_outside_nodes(outside)
    )

    x = x + @layer_gap

    # Layer 2: Interface
    {interface_elems, x} = render_layer(
      x, @margin + 20, layout.layer_h,
      "Interface", @layer_bg_interface, @layer_border_interface,
      render_module_nodes(layers.interface, @layer_border_interface, 8)
    )

    x = x + @layer_gap

    # Layer 3: Domain (with state machines)
    domain_nodes = render_module_nodes(layers.domain, @layer_border_domain, 8)
    sm_nodes = render_state_machine_nodes(state_machines)

    {domain_elems, x} = render_layer(
      x, @margin + 20, layout.layer_h,
      "Domain", @layer_bg_domain, @layer_border_domain,
      domain_nodes ++ sm_nodes
    )

    x = x + @layer_gap

    # Layer 4: Infrastructure
    {infra_elems, x} = render_layer(
      x, @margin + 20, layout.layer_h,
      "Infrastructure", @layer_bg_infra, @layer_border_infra,
      render_module_nodes(layers.infrastructure, @layer_border_infra, 6)
    )

    x = x + @layer_gap

    # Layer 5: Inside Tools
    {tools_elems, _x} = render_layer(
      x, @margin + 20, layout.layer_h,
      "Inside Tools", @layer_bg_tools, @layer_border_tools,
      render_tool_nodes(tools)
    )

    # Flow arrows between layers
    arrows = render_flow_arrows(layout)

    # Title
    title = [
      ~s[<text x="#{@margin}" y="16" fill="#{@text}" font-size="13" font-weight="600" font-family="monospace">System Architecture — #{map_size(graph.modules)} modules</text>]
    ]

    all = title ++ outside_elems ++ interface_elems ++ domain_elems ++ infra_elems ++ tools_elems ++ arrows
    wrap_svg(all, layout.total_w, layout.total_h)
  end

  defp render_layer(x, y, height, title, bg_color, border_color, node_renderers) do
    w = @node_w + 20

    frame = [
      ~s[<rect x="#{x}" y="#{y}" width="#{w}" height="#{height}" rx="8" fill="#{bg_color}" stroke="#{border_color}" stroke-width="1.5" opacity="0.6"/>],
      ~s[<text x="#{x + w / 2}" y="#{y + 18}" text-anchor="middle" fill="#{border_color}" font-size="11" font-weight="600" font-family="monospace">#{title}</text>]
    ]

    node_elems =
      node_renderers
      |> Enum.with_index()
      |> Enum.flat_map(fn {renderer, idx} ->
        ny = y + @layer_header + 8 + idx * (@node_h + @node_gap)
        renderer.(x + 10, ny)
      end)

    {frame ++ node_elems, x + w}
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

    connections
    |> Enum.map(fn conn ->
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
      name = short_name(mod)

      fn x, y ->
        [
          ~s[<rect x="#{x}" y="#{y}" width="#{@node_w}" height="#{@node_h}" rx="6" fill="#2D2D3F" stroke="#{accent_color}" stroke-width="1"/>],
          ~s[<text x="#{x + 10}" y="#{y + 20}" fill="#{accent_color}" font-size="11" font-weight="500" font-family="monospace">#{name}</text>],
          ~s[<text x="#{x + 10}" y="#{y + 34}" fill="#{@dim}" font-size="8" font-family="monospace">#{format_mod(mod)}</text>]
        ]
      end
    end)
  end

  defp render_state_machine_nodes(state_machines) do
    state_machines
    |> Enum.take(3)
    |> Enum.map(fn {mod, sm_info} ->
      name = short_name(mod)
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

    tools
    |> Enum.map(fn tool ->
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

  defp render_flow_arrows(layout) do
    # Horizontal flow arrows between layers
    y_mid = @margin + 20 + layout.layer_h / 2
    layer_w = @node_w + 20

    0..3
    |> Enum.flat_map(fn i ->
      x_start = @margin + (i + 1) * layer_w + i * @layer_gap - 4
      x_end = x_start + @layer_gap + 8

      [
        ~s[<defs><marker id="arrowhead" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto"><polygon points="0 0, 8 3, 0 6" fill="#{@wire_color}" opacity="0.5"/></marker></defs>],
        ~s[<line x1="#{x_start}" y1="#{y_mid}" x2="#{x_end}" y2="#{y_mid}" stroke="#{@wire_color}" stroke-width="2" opacity="0.3" marker-end="url(#arrowhead)"/>]
      ]
    end)
    |> Enum.uniq()
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

  defp format_mod(mod) do
    mod
    |> Atom.to_string()
    |> String.replace_leading("Elixir.", "")
  end

  defp short_name(mod) do
    mod
    |> Module.split()
    |> List.last()
  end
end
