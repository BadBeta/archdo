defmodule Archdo.Compiled.DiagramSVG do
  @moduledoc false

  # Generates SVG dataflow diagrams from the compiled interaction graph.
  # Inspired by LabVIEW block diagrams and Grasshopper component graphs.
  #
  # Each module is a box with:
  #   - Input ports (left): functions called by incoming modules
  #   - Body: module name + export list
  #   - Output ports (right): functions this module calls on others
  #
  # Wire types encoded visually:
  #   - Color: data type (blue=ok/error, orange=atom, green=list, purple=map)
  #   - Thickness: call frequency (thin=1-2, medium=3-9, thick=10+)
  #   - Style: solid=synchronous call, dashed=async/cast/send

  alias Archdo.AST
  alias Archdo.Compiled.{DiagramHelpers, Graph}

  # Layout constants
  @node_width 220
  @port_height 18
  @node_header 32
  @node_padding 8
  @col_gap 280
  @row_gap 24
  @port_radius 5
  @font_size 11
  @header_font_size 13

  # Colors
  @node_bg "#2D2D3F"
  @node_border "#4A4A6A"
  @node_header_bg "#3D3D5C"
  @text_color "#CDD6F4"
  @dim_text "#6C7086"
  @port_text "#BAC2DE"
  @wire_ok "#89B4FA"
  @wire_error "#F38BA8"
  @wire_atom "#FAB387"
  @wire_list "#A6E3A1"
  @wire_map "#CBA6F7"
  @wire_default "#7F849C"
  @boundary_border "#45475A"
  @boundary_bg "#1E1E2E"
  @accent "#89DCEB"

  @doc """
  Generate an SVG dataflow diagram for a single module showing it as a
  LabVIEW-style component with input/output ports and typed wires.
  """
  @spec module_dataflow(Graph.t(), module()) :: String.t()
  def module_dataflow(%Graph{} = graph, module) do
    incoming = Graph.known_by(graph, module)
    outgoing = Graph.knows_about(graph, module)

    # Get export info
    clauses_map =
      case graph.beam_dir do
        nil -> %{}
        dir -> Graph.extract_function_clauses(dir)
      end

    functions = Map.get(clauses_map, module, [])
    exports = Enum.filter(functions, & &1.exported)

    # Layout: three columns — callers | module | dependencies
    callers = Enum.take(incoming, 8)
    deps = Enum.take(outgoing, 8)

    # Calculate dimensions
    export_count = min(length(exports), 12)
    caller_port_count = length(callers)
    dep_port_count = length(deps)

    center_height = max(@node_header + export_count * @port_height + @node_padding * 2, 120)
    left_height = max(caller_port_count * (40 + @row_gap), center_height)
    right_height = max(dep_port_count * (40 + @row_gap), center_height)
    total_height = max(left_height, max(center_height, right_height)) + 60

    center_x = @col_gap + @node_width + 40
    center_y = 30 + (total_height - center_height) / 2

    total_width = center_x + @node_width + @col_gap + @node_width + 80

    elements = []

    # Render callers (left column)
    {caller_elements, caller_ports} =
      render_column(callers, 40, 30, total_height - 60, :caller)

    # Render center module
    center_elements = render_module_box(module, exports, center_x, center_y, center_height)

    # Render dependencies (right column)
    dep_x = center_x + @node_width + @col_gap
    {dep_elements, dep_ports} =
      render_column(deps, dep_x, 30, total_height - 60, :dependency)

    # Render wires from callers to center
    caller_wires =
      callers
      |> Enum.with_index()
      |> Enum.flat_map(fn {entry, idx} ->
        from_port = Map.get(caller_ports, idx, {0, 0})
        # Target port on center module left side
        to_y = center_y + @node_header + idx * @port_height + @port_height / 2
        to_port = {center_x, to_y}
        render_wire(from_port, to_port, entry.call_count, :incoming)
      end)

    # Render wires from center to deps
    dep_wires =
      deps
      |> Enum.with_index()
      |> Enum.flat_map(fn {entry, idx} ->
        from_y = center_y + @node_header + idx * @port_height + @port_height / 2
        from_port = {center_x + @node_width, from_y}
        to_port = Map.get(dep_ports, idx, {0, 0})
        render_wire(from_port, to_port, entry.call_count, :outgoing)
      end)

    all_elements =
      elements ++ caller_elements ++ center_elements ++ dep_elements ++ caller_wires ++ dep_wires

    DiagramHelpers.wrap_svg(all_elements, total_width, total_height)
  end

  @doc """
  Generate an SVG dataflow diagram for an entire context showing
  internal structure with typed connections.
  """
  @spec context_dataflow(Graph.t(), String.t()) :: String.t()
  def context_dataflow(%Graph{} = graph, context_name) do
    contexts = Graph.discover_contexts(graph)

    case Enum.find(contexts, fn c -> c.context == context_name end) do
      nil ->
        DiagramHelpers.error_svg("Context '#{context_name}' not found", @wire_error)

      ctx ->
        render_context_svg(graph, ctx)
    end
  end

  # --- Rendering helpers ---

  defp render_module_box(module, exports, x, y, height) do
    mod_name = AST.short_name(module)
    full_name = AST.module_name(module)

    # Header
    header = [
      ~s(<rect x="#{x}" y="#{y}" width="#{@node_width}" height="#{height}" rx="6" fill="#{@node_bg}" stroke="#{@node_border}" stroke-width="1.5"/>),
      ~s(<rect x="#{x}" y="#{y}" width="#{@node_width}" height="#{@node_header}" rx="6" fill="#{@node_header_bg}"/>),
      ~s(<rect x="#{x}" y="#{y + @node_header - 6}" width="#{@node_width}" height="6" fill="#{@node_header_bg}"/>),
      ~s(<text x="#{x + @node_width / 2}" y="#{y + 20}" text-anchor="middle" fill="#{@accent}" font-size="#{@header_font_size}" font-weight="600" font-family="monospace">#{mod_name}</text>),
      ~s(<text x="#{x + @node_width / 2}" y="#{y + @node_header + @port_height / 2 - 2}" text-anchor="middle" fill="#{@dim_text}" font-size="9" font-family="monospace">#{full_name}</text>)
    ]

    # Export list with ports
    export_lines =
      exports
      |> Enum.take(12)
      |> Enum.with_index()
      |> Enum.flat_map(fn {fn_info, idx} ->
        py = y + @node_header + @node_padding + idx * @port_height + @port_height / 2 + 8
        return_str = format_return_tag(fn_info)

        # Input port (left)
        input_port = ~s(<circle cx="#{x}" cy="#{py}" r="#{@port_radius}" fill="#{wire_color_for_fn(fn_info)}" stroke="#{@node_border}"/>)

        # Output port (right)
        output_port = ~s(<circle cx="#{x + @node_width}" cy="#{py}" r="#{@port_radius}" fill="#{wire_color_for_fn(fn_info)}" stroke="#{@node_border}"/>)

        # Function name
        fn_text = ~s(<text x="#{x + 14}" y="#{py + 4}" fill="#{@port_text}" font-size="#{@font_size}" font-family="monospace">#{fn_info.name}/#{fn_info.arity}</text>)

        # Return type (right-aligned)
        ret_text = ~s(<text x="#{x + @node_width - 14}" y="#{py + 4}" text-anchor="end" fill="#{@dim_text}" font-size="10" font-family="monospace">#{return_str}</text>)

        [input_port, output_port, fn_text, ret_text]
      end)

    header ++ export_lines
  end

  defp render_column(entries, x, y_start, available_height, role) do
    count = length(entries)

    case count do
      0 ->
        {[], %{}}

      _ ->
        spacing = min(available_height / count, 60)

        {elements, ports} =
          entries
          |> Enum.with_index()
          |> Enum.reduce({[], %{}}, fn {entry, idx}, {elems, ports} ->
            ey = y_start + idx * spacing
            node_h = 36

            mod_name = AST.short_name(entry.module)
            fns = Enum.map_join(entry.functions_called, ", ", fn {f, a} -> "#{f}/#{a}" end)
            fns_truncated = String.slice(fns, 0, 28)

            bg_color =
              case role do
                :caller -> "#1E3A5F"
                :dependency -> "#3D2E1E"
              end

            border_color =
              case role do
                :caller -> "#2563EB"
                :dependency -> "#D97706"
              end

            box = [
              ~s(<rect x="#{x}" y="#{ey}" width="#{@node_width}" height="#{node_h}" rx="4" fill="#{bg_color}" stroke="#{border_color}" stroke-width="1"/>),
              ~s(<text x="#{x + 10}" y="#{ey + 15}" fill="#{@text_color}" font-size="#{@font_size}" font-weight="500" font-family="monospace">#{mod_name}</text>),
              ~s(<text x="#{x + 10}" y="#{ey + 28}" fill="#{@dim_text}" font-size="9" font-family="monospace">#{fns_truncated}</text>)
            ]

            # Port position
            port =
              case role do
                :caller -> {x + @node_width, ey + node_h / 2}
                :dependency -> {x, ey + node_h / 2}
              end

            port_circle = [
              ~s(<circle cx="#{elem(port, 0)}" cy="#{elem(port, 1)}" r="#{@port_radius}" fill="#{border_color}" stroke="#{@node_border}"/>)
            ]

            {elems ++ box ++ port_circle, Map.put(ports, idx, port)}
          end)

        {elements, ports}
    end
  end

  defp render_wire({x1, y1}, {x2, y2}, call_count, _direction) do
    # Bezier control points for smooth curve
    mid_x = (x1 + x2) / 2
    cp1_x = x1 + (mid_x - x1) * 0.6
    cp2_x = x2 - (mid_x - x1) * 0.6

    thickness =
      cond do
        call_count >= 10 -> 3
        call_count >= 3 -> 2
        true -> 1.2
      end

    color =
      cond do
        call_count >= 10 -> @wire_ok
        call_count >= 3 -> @wire_default
        true -> @wire_default
      end

    opacity =
      cond do
        call_count >= 10 -> "0.9"
        call_count >= 3 -> "0.6"
        true -> "0.35"
      end

    [
      ~s(<path d="M #{x1} #{y1} C #{cp1_x} #{y1}, #{cp2_x} #{y2}, #{x2} #{y2}" fill="none" stroke="#{color}" stroke-width="#{thickness}" opacity="#{opacity}"/>)
    ]
  end

  defp render_context_svg(graph, ctx) do
    member_set = MapSet.new(ctx.members)
    members = Enum.take(ctx.members, 16)

    # Layout members in a grid
    cols = 3
    rows = ceil(length(members) / cols)
    node_w = 180
    node_h = 36
    gap_x = 30
    gap_y = 16
    margin = 60

    grid_w = cols * (node_w + gap_x) - gap_x
    grid_h = rows * (node_h + gap_y) - gap_y

    frame_w = grid_w + margin * 2
    frame_h = grid_h + margin * 2 + 40

    # External callers
    ext_callers =
      ctx.members
      |> Enum.flat_map(fn mod ->
        Enum.reject(Graph.known_by(graph, mod), fn e -> MapSet.member?(member_set, e.module) end)
      end)
      |> Enum.uniq_by(& &1.module)
      |> Enum.take(6)

    # External deps
    ext_deps =
      ctx.members
      |> Enum.flat_map(fn mod ->
        Enum.reject(Graph.knows_about(graph, mod), fn e -> MapSet.member?(member_set, e.module) end)
      end)
      |> Enum.uniq_by(& &1.module)
      |> Enum.take(6)

    left_col_w = case ext_callers do [] -> 0; _ -> @node_width + @col_gap end
    right_col_w = case ext_deps do [] -> 0; _ -> @col_gap + @node_width end

    total_w = left_col_w + frame_w + right_col_w + 40
    total_h = max(frame_h, max(length(ext_callers), length(ext_deps)) * 50) + 60

    frame_x = left_col_w + 20
    frame_y = 30

    # Context frame
    frame_elements = [
      ~s(<rect x="#{frame_x}" y="#{frame_y}" width="#{frame_w}" height="#{frame_h}" rx="8" fill="#{@boundary_bg}" stroke="#{@boundary_border}" stroke-width="2" stroke-dasharray="6,3"/>),
      ~s(<text x="#{frame_x + frame_w / 2}" y="#{frame_y + 22}" text-anchor="middle" fill="#{@accent}" font-size="14" font-weight="600" font-family="monospace">#{ctx.context}</text>),
      ~s(<text x="#{frame_x + frame_w / 2}" y="#{frame_y + 38}" text-anchor="middle" fill="#{@dim_text}" font-size="10" font-family="monospace">cohesion: #{ctx.cohesion} | coupling: #{ctx.coupling} | #{length(ctx.members)} modules</text>)
    ]

    # Members inside the frame
    member_elements =
      members
      |> Enum.with_index()
      |> Enum.flat_map(fn {mod, idx} ->
        col = rem(idx, cols)
        row = div(idx, cols)
        mx = frame_x + margin + col * (node_w + gap_x)
        my = frame_y + margin + 20 + row * (node_h + gap_y)

        is_boundary = mod == ctx.boundary_module

        bg =
          case is_boundary do
            true -> "#2D4F3D"
            false -> @node_bg
          end

        border =
          case is_boundary do
            true -> "#4CAF50"
            false -> @node_border
          end

        label =
          case is_boundary do
            true -> "#{AST.short_name(mod)} [BOUNDARY]"
            false -> AST.short_name(mod)
          end

        [
          ~s(<rect x="#{mx}" y="#{my}" width="#{node_w}" height="#{node_h}" rx="4" fill="#{bg}" stroke="#{border}" stroke-width="1.5"/>),
          ~s(<text x="#{mx + node_w / 2}" y="#{my + 22}" text-anchor="middle" fill="#{@text_color}" font-size="#{@font_size}" font-family="monospace">#{label}</text>)
        ]
      end)

    # External callers (left)
    caller_elements =
      ext_callers
      |> Enum.with_index()
      |> Enum.flat_map(fn {entry, idx} ->
        ey = 40 + idx * 50
        [
          ~s(<rect x="20" y="#{ey}" width="#{@node_width}" height="36" rx="4" fill="#1E3A5F" stroke="#2563EB" stroke-width="1"/>),
          ~s(<text x="30" y="#{ey + 22}" fill="#{@text_color}" font-size="#{@font_size}" font-family="monospace">#{AST.short_name(entry.module)}</text>),
          ~s(<path d="M #{20 + @node_width} #{ey + 18} L #{frame_x} #{frame_y + frame_h / 2}" fill="none" stroke="#{@wire_ok}" stroke-width="1.2" opacity="0.4"/>)
        ]
      end)

    # External deps (right)
    dep_elements =
      ext_deps
      |> Enum.with_index()
      |> Enum.flat_map(fn {entry, idx} ->
        ey = 40 + idx * 50
        dx = frame_x + frame_w + @col_gap
        [
          ~s(<rect x="#{dx}" y="#{ey}" width="#{@node_width}" height="36" rx="4" fill="#3D2E1E" stroke="#D97706" stroke-width="1"/>),
          ~s(<text x="#{dx + 10}" y="#{ey + 22}" fill="#{@text_color}" font-size="#{@font_size}" font-family="monospace">#{AST.short_name(entry.module)}</text>),
          ~s(<path d="M #{frame_x + frame_w} #{frame_y + frame_h / 2} L #{dx} #{ey + 18}" fill="none" stroke="#{@wire_atom}" stroke-width="1.2" opacity="0.4" stroke-dasharray="4,2"/>)
        ]
      end)

    all = frame_elements ++ member_elements ++ caller_elements ++ dep_elements
    DiagramHelpers.wrap_svg(all, total_w, total_h)
  end

  defp wire_color_for_fn(fn_info) do
    shapes =
      fn_info.clauses
      |> Enum.map(& &1.return_shape)
      |> Enum.uniq()

    tags = for {:tagged_tuple, t} <- shapes, do: t

    cond do
      :ok in tags and :error in tags -> @wire_ok
      :ok in tags -> @wire_ok
      :error in tags -> @wire_error
      Enum.any?(shapes, &(&1 == :list)) -> @wire_list
      Enum.any?(shapes, &(&1 == :map)) -> @wire_map
      Enum.any?(shapes, &match?({:atom, _}, &1)) -> @wire_atom
      true -> @wire_default
    end
  end

  defp format_return_tag(fn_info) do
    shapes =
      fn_info.clauses
      |> Enum.map(& &1.return_shape)
      |> Enum.uniq()

    case shapes do
      [{:tagged_tuple, :ok}] -> "{:ok, _}"
      [{:tagged_tuple, :error}] -> "{:error, _}"
      [{:atom, val}] -> ":#{val}"
      [:list] -> "[...]"
      [:map] -> "%{}"
      [:call] -> "fn()"
      _ ->
        tags = for {:tagged_tuple, t} <- shapes, do: t

        case tags do
          [] -> ""
          _ -> Enum.map_join(tags, "|", &":#{&1}")
        end
    end
  end
end
