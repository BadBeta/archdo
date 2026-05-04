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
  alias Archdo.Compiled.{SvgDocument, Graph, Query}

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
  def module_dataflow(graph, module) do
    incoming = Query.known_by(graph, module)
    outgoing = Query.knows_about(graph, module)

    # Get export info
    clauses_map =
      case Graph.beam_dir(graph) do
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

    SvgDocument.wrap_svg(all_elements, total_width, total_height)
  end

  @doc """
  Generate an SVG dataflow diagram for an entire context showing
  internal structure with typed connections.
  """
  @spec context_dataflow(Graph.t(), String.t()) :: String.t()
  def context_dataflow(graph, context_name) do
    contexts = Query.discover_contexts(graph)

    case Enum.find(contexts, fn c -> c.context == context_name end) do
      nil ->
        SvgDocument.error_svg("Context '#{context_name}' not found", @wire_error)

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
        input_port =
          ~s(<circle cx="#{x}" cy="#{py}" r="#{@port_radius}" fill="#{wire_color_for_fn(fn_info)}" stroke="#{@node_border}"/>)

        # Output port (right)
        output_port =
          ~s(<circle cx="#{x + @node_width}" cy="#{py}" r="#{@port_radius}" fill="#{wire_color_for_fn(fn_info)}" stroke="#{@node_border}"/>)

        # Function name
        fn_text =
          ~s(<text x="#{x + 14}" y="#{py + 4}" fill="#{@port_text}" font-size="#{@font_size}" font-family="monospace">#{fn_info.name}/#{fn_info.arity}</text>)

        # Return type (right-aligned)
        ret_text =
          ~s(<text x="#{x + @node_width - 14}" y="#{py + 4}" text-anchor="end" fill="#{@dim_text}" font-size="10" font-family="monospace">#{return_str}</text>)

        [input_port, output_port, fn_text, ret_text]
      end)

    header ++ export_lines
  end

  defp render_column(entries, x, y_start, available_height, role) do
    render_column_entries(length(entries), entries, x, y_start, available_height, role)
  end

  # §§ elixir-implementing: §2.1 — empty-vs-nonempty dispatch on count.
  defp render_column_entries(0, _entries, _x, _y_start, _avail, _role), do: {[], %{}}

  defp render_column_entries(count, entries, x, y_start, available_height, role) do
    spacing = min(available_height / count, 60)

    {elements, ports} =
      entries
      |> Enum.with_index()
      |> Enum.reduce({[], %{}}, &accumulate_column_entry(&1, &2, x, y_start, spacing, role))

    {List.flatten(Enum.reverse(elements)), ports}
  end

  defp accumulate_column_entry({entry, idx}, {elems, ports}, x, y_start, spacing, role) do
    ey = y_start + idx * spacing
    node_h = 36

    mod_name = AST.short_name(entry.module)
    fns = Enum.map_join(entry.functions_called, ", ", fn {f, a} -> "#{f}/#{a}" end)
    fns_truncated = String.slice(fns, 0, 28)

    bg_color = column_bg_color(role)
    border_color = column_border_color(role)
    port = column_port(role, x, ey, node_h)

    box = [
      ~s(<rect x="#{x}" y="#{ey}" width="#{@node_width}" height="#{node_h}" rx="4" fill="#{bg_color}" stroke="#{border_color}" stroke-width="1"/>),
      ~s(<text x="#{x + 10}" y="#{ey + 15}" fill="#{@text_color}" font-size="#{@font_size}" font-weight="500" font-family="monospace">#{mod_name}</text>),
      ~s(<text x="#{x + 10}" y="#{ey + 28}" fill="#{@dim_text}" font-size="9" font-family="monospace">#{fns_truncated}</text>)
    ]

    port_circle = [
      ~s(<circle cx="#{elem(port, 0)}" cy="#{elem(port, 1)}" r="#{@port_radius}" fill="#{border_color}" stroke="#{@node_border}"/>)
    ]

    {[port_circle, box | elems], Map.put(ports, idx, port)}
  end

  defp column_bg_color(:caller), do: "#1E3A5F"
  defp column_bg_color(:dependency), do: "#3D2E1E"

  defp column_border_color(:caller), do: "#2563EB"
  defp column_border_color(:dependency), do: "#D97706"

  defp column_port(:caller, x, ey, node_h), do: {x + @node_width, ey + node_h / 2}
  defp column_port(:dependency, x, ey, node_h), do: {x, ey + node_h / 2}

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

  @ctx_max_members 16
  @ctx_max_externals 6
  @ctx_grid_cols 3
  @ctx_node_w 180
  @ctx_node_h 36
  @ctx_grid_gap_x 30
  @ctx_grid_gap_y 16
  @ctx_frame_margin 60

  defp render_context_svg(graph, ctx) do
    layout = compute_context_layout(graph, ctx)
    elements = build_context_elements(ctx, layout)
    SvgDocument.wrap_svg(elements, layout.total_w, layout.total_h)
  end

  defp compute_context_layout(graph, ctx) do
    member_set = MapSet.new(ctx.members)
    members = Enum.take(ctx.members, @ctx_max_members)
    rows = ceil(length(members) / @ctx_grid_cols)

    grid_w = @ctx_grid_cols * (@ctx_node_w + @ctx_grid_gap_x) - @ctx_grid_gap_x
    grid_h = rows * (@ctx_node_h + @ctx_grid_gap_y) - @ctx_grid_gap_y
    frame_w = grid_w + @ctx_frame_margin * 2
    frame_h = grid_h + @ctx_frame_margin * 2 + 40

    ext_callers = collect_external_callers(graph, ctx, member_set)
    ext_deps = collect_external_deps(graph, ctx, member_set)

    left_col_w = column_width(ext_callers, @node_width + @col_gap)
    right_col_w = column_width(ext_deps, @col_gap + @node_width)

    %{
      members: members,
      ext_callers: ext_callers,
      ext_deps: ext_deps,
      frame_x: left_col_w + 20,
      frame_y: 30,
      frame_w: frame_w,
      frame_h: frame_h,
      total_w: left_col_w + frame_w + right_col_w + 40,
      total_h: max(frame_h, max(length(ext_callers), length(ext_deps)) * 50) + 60
    }
  end

  @doc false
  # Column width — zero when there are no entries to render in that
  # column, the configured width otherwise. @doc false for testability
  # (it's a tiny pure helper but pinning the empty/non-empty contract
  # in a test prevents future "default to width" regressions).
  @spec column_width(list(), non_neg_integer()) :: non_neg_integer()
  def column_width([], _), do: 0
  def column_width(_, width), do: width

  @doc false
  # Pick {bg, border, label} for a member box. is_boundary? is the
  # caller's pre-computed `mod == ctx.boundary_module` so this stays a
  # pure data function.
  @spec member_style(boolean(), module()) :: {String.t(), String.t(), String.t()}
  def member_style(true, mod),
    do: {"#2D4F3D", "#4CAF50", "#{AST.short_name(mod)} [BOUNDARY]"}

  def member_style(false, mod), do: {@node_bg, @node_border, AST.short_name(mod)}

  defp collect_external_callers(graph, ctx, member_set) do
    ctx.members
    |> Enum.flat_map(fn mod ->
      Enum.reject(Query.known_by(graph, mod), &MapSet.member?(member_set, &1.module))
    end)
    |> Enum.uniq_by(& &1.module)
    |> Enum.take(@ctx_max_externals)
  end

  defp collect_external_deps(graph, ctx, member_set) do
    ctx.members
    |> Enum.flat_map(fn mod ->
      Enum.reject(Query.knows_about(graph, mod), &MapSet.member?(member_set, &1.module))
    end)
    |> Enum.uniq_by(& &1.module)
    |> Enum.take(@ctx_max_externals)
  end

  defp build_context_elements(ctx, layout) do
    frame_elements(ctx, layout) ++
      member_elements(ctx, layout) ++
      caller_elements(layout) ++
      dep_elements(layout)
  end

  defp frame_elements(ctx, %{frame_x: fx, frame_y: fy, frame_w: fw, frame_h: fh}) do
    [
      ~s(<rect x="#{fx}" y="#{fy}" width="#{fw}" height="#{fh}" rx="8" fill="#{@boundary_bg}" stroke="#{@boundary_border}" stroke-width="2" stroke-dasharray="6,3"/>),
      ~s(<text x="#{fx + fw / 2}" y="#{fy + 22}" text-anchor="middle" fill="#{@accent}" font-size="14" font-weight="600" font-family="monospace">#{ctx.context}</text>),
      ~s(<text x="#{fx + fw / 2}" y="#{fy + 38}" text-anchor="middle" fill="#{@dim_text}" font-size="10" font-family="monospace">cohesion: #{ctx.cohesion} | coupling: #{ctx.coupling} | #{length(ctx.members)} modules</text>)
    ]
  end

  defp member_elements(ctx, layout) do
    layout.members
    |> Enum.with_index()
    |> Enum.flat_map(&member_element(&1, ctx, layout))
  end

  defp member_element({mod, idx}, ctx, layout) do
    col = rem(idx, @ctx_grid_cols)
    row = div(idx, @ctx_grid_cols)
    mx = layout.frame_x + @ctx_frame_margin + col * (@ctx_node_w + @ctx_grid_gap_x)
    my = layout.frame_y + @ctx_frame_margin + 20 + row * (@ctx_node_h + @ctx_grid_gap_y)

    {bg, border, label} = member_style(mod == ctx.boundary_module, mod)

    [
      ~s(<rect x="#{mx}" y="#{my}" width="#{@ctx_node_w}" height="#{@ctx_node_h}" rx="4" fill="#{bg}" stroke="#{border}" stroke-width="1.5"/>),
      ~s(<text x="#{mx + @ctx_node_w / 2}" y="#{my + 22}" text-anchor="middle" fill="#{@text_color}" font-size="#{@font_size}" font-family="monospace">#{label}</text>)
    ]
  end

  defp caller_elements(layout) do
    layout.ext_callers
    |> Enum.with_index()
    |> Enum.flat_map(&caller_element(&1, layout))
  end

  defp caller_element({entry, idx}, layout) do
    ey = 40 + idx * 50

    [
      ~s(<rect x="20" y="#{ey}" width="#{@node_width}" height="36" rx="4" fill="#1E3A5F" stroke="#2563EB" stroke-width="1"/>),
      ~s(<text x="30" y="#{ey + 22}" fill="#{@text_color}" font-size="#{@font_size}" font-family="monospace">#{AST.short_name(entry.module)}</text>),
      ~s(<path d="M #{20 + @node_width} #{ey + 18} L #{layout.frame_x} #{layout.frame_y + layout.frame_h / 2}" fill="none" stroke="#{@wire_ok}" stroke-width="1.2" opacity="0.4"/>)
    ]
  end

  defp dep_elements(layout) do
    layout.ext_deps
    |> Enum.with_index()
    |> Enum.flat_map(&dep_element(&1, layout))
  end

  defp dep_element({entry, idx}, layout) do
    ey = 40 + idx * 50
    dx = layout.frame_x + layout.frame_w + @col_gap

    [
      ~s(<rect x="#{dx}" y="#{ey}" width="#{@node_width}" height="36" rx="4" fill="#3D2E1E" stroke="#D97706" stroke-width="1"/>),
      ~s(<text x="#{dx + 10}" y="#{ey + 22}" fill="#{@text_color}" font-size="#{@font_size}" font-family="monospace">#{AST.short_name(entry.module)}</text>),
      ~s(<path d="M #{layout.frame_x + layout.frame_w} #{layout.frame_y + layout.frame_h / 2} L #{dx} #{ey + 18}" fill="none" stroke="#{@wire_atom}" stroke-width="1.2" opacity="0.4" stroke-dasharray="4,2"/>)
    ]
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
      [{:tagged_tuple, :ok}] ->
        "{:ok, _}"

      [{:tagged_tuple, :error}] ->
        "{:error, _}"

      [{:atom, val}] ->
        ":#{val}"

      [:list] ->
        "[...]"

      [:map] ->
        "%{}"

      [:call] ->
        "fn()"

      _ ->
        tags = for {:tagged_tuple, t} <- shapes, do: t

        case tags do
          [] -> ""
          _ -> Enum.map_join(tags, "|", &":#{&1}")
        end
    end
  end
end
