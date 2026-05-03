defmodule Archdo.Compiled.DiagramOTP do
  @moduledoc false

  # Generates SVG diagrams of OTP supervision trees and process messaging.
  #
  # Visual model:
  #   - Each process is a rounded box with:
  #     - Mailbox (incoming queue) icon at top-left corner
  #     - Outbox (outgoing queue) icon at bottom-right corner
  #   - Supervisors are dashed frames containing their children
  #   - Message wires: dashed lines from outbox → mailbox
  #   - Supervision links: solid lines from supervisor frame to child

  alias Archdo.AST
  alias Archdo.Compiled.{DiagramHelpers, Graph, OTPTopology}

  # Layout constants
  @process_w 200
  @process_h 56
  @mailbox_size 14
  @sup_padding 24
  @sup_header 30
  @child_gap_x 20
  # @child_gap_y 16
  @margin 40

  # Colors (dark theme matching DiagramSVG)
  @bg "#1E1E2E"
  @process_bg "#2D2D3F"
  @process_border "#4A4A6A"
  @sup_bg "#1A1A2A"
  # @sup_border "#45475A"
  @genserver_accent "#89B4FA"
  @supervisor_accent "#A6E3A1"
  @agent_accent "#FAB387"
  @task_accent "#F5C2E7"
  @mailbox_in "#89DCEB"
  @mailbox_out "#F9E2AF"
  # @msg_wire "#7F849C"
  @text_color "#CDD6F4"
  @dim_text "#6C7086"

  @doc """
  Generate an SVG diagram showing the OTP supervision tree with process
  mailboxes and message-passing relationships.
  """
  @spec supervision_diagram(Graph.t()) :: String.t()
  def supervision_diagram(graph) do
    topology = OTPTopology.extract(graph)

    case topology do
      [] ->
        no_otp_svg()

      _ ->
        tree = OTPTopology.supervision_tree(topology)
        # Also include orphan processes (not supervised by any detected supervisor)
        supervised_set =
          topology
          |> Enum.flat_map(& &1.children)
          |> MapSet.new()

        orphans =
          Enum.reject(topology, fn p ->
            p.type == :supervisor or MapSet.member?(supervised_set, p.module)
          end)

        render_full_diagram(tree, orphans, topology)
    end
  end

  @doc """
  Generate an SVG diagram showing only message-passing relationships
  between processes (no supervision tree structure).
  """
  @spec messaging_diagram(Graph.t()) :: String.t()
  def messaging_diagram(graph) do
    topology = OTPTopology.extract(graph)

    case topology do
      [] ->
        no_otp_svg()

      _ ->
        render_messaging_diagram(topology)
    end
  end

  # --- Full supervision + messaging diagram ---

  defp render_full_diagram(tree, orphans, topology) do
    # Lay out the supervision tree
    {tree_elements, tree_w, tree_h} = layout_tree(tree, @margin, @margin + 30)

    # Lay out orphan processes below the tree
    {orphan_elements, orphan_h} = layout_orphans(orphans, @margin, @margin + tree_h + 50)

    # Message wires between processes
    # (simplified — show inter-process calls)
    msg_elements = layout_messages(topology, @margin, @margin + 30)

    total_w = max(tree_w + @margin * 2, 600)
    total_h = @margin + 30 + tree_h + orphan_h + 80

    # Title
    title = [
      ~s(<text x="#{@margin}" y="24" fill="#{@text_color}" font-size="14" font-weight="600" font-family="monospace">OTP Supervision Tree</text>)
    ]

    # Legend
    legend = render_legend(total_w - 260, 8)

    all = title ++ legend ++ tree_elements ++ orphan_elements ++ msg_elements
    DiagramHelpers.wrap_svg(all, total_w, total_h)
  end

  defp layout_tree([], _x, _y), do: {[], 0, 0}

  defp layout_tree(roots, start_x, start_y) do
    {elements, total_w, total_h, _x_cursor} =
      Enum.reduce(roots, {[], 0, 0, start_x}, fn root, {elems, max_w, max_h, x} ->
        {node_elems, w, h} = layout_tree_node(root, x, start_y, 0)
        new_x = x + w + @child_gap_x * 2
        {[node_elems | elems], max(max_w, new_x - start_x), max(max_h, h), new_x}
      end)

    {List.flatten(Enum.reverse(elements)), total_w, total_h}
  end

  defp layout_tree_node(%{process: process, children: []}, x, y, _depth) do
    # Leaf process — just a box
    elements = render_process_box(process, x, y)
    {@process_w, @process_h}
    {elements, @process_w, @process_h}
  end

  defp layout_tree_node(%{process: process, children: children}, x, y, depth) do
    # Supervisor with children — frame containing children

    # Layout children horizontally inside the frame
    children_start_x = x + @sup_padding
    children_start_y = y + @sup_header + @sup_padding

    {child_elements, children_total_w, children_max_h, _x_cursor} =
      Enum.reduce(children, {[], 0, 0, children_start_x}, fn child, {elems, total_w, max_h, cx} ->
        {child_elems, cw, ch} = layout_tree_node(child, cx, children_start_y, depth + 1)
        new_cx = cx + cw + @child_gap_x
        {[child_elems | elems], total_w + cw + @child_gap_x, max(max_h, ch), new_cx}
      end)

    child_elements = List.flatten(Enum.reverse(child_elements))

    # Frame dimensions
    frame_w = max(children_total_w + @sup_padding, @process_w + @sup_padding * 2)
    frame_h = @sup_header + @sup_padding + children_max_h + @sup_padding

    # Strategy label
    strategy_str =
      case process.supervision_strategy do
        nil -> ""
        s -> " :#{s}"
      end

    # Supervisor frame
    frame_elements = [
      ~s(<rect x="#{x}" y="#{y}" width="#{frame_w}" height="#{frame_h}" rx="8" fill="#{@sup_bg}" stroke="#{@supervisor_accent}" stroke-width="1.5" stroke-dasharray="6,3" opacity="0.8"/>),
      ~s(<text x="#{x + 10}" y="#{y + 18}" fill="#{@supervisor_accent}" font-size="12" font-weight="600" font-family="monospace">⬡ #{AST.short_name(process.module)}#{strategy_str}</text>),
      # Mailbox in (top-left of frame)
      render_mailbox_in(x + 2, y + 2),
      # Outbox (bottom-right of frame)
      render_mailbox_out(x + frame_w - @mailbox_size - 2, y + frame_h - @mailbox_size - 2)
    ]

    {frame_elements ++ child_elements, frame_w, frame_h}
  end

  defp layout_orphans([], _x, _y), do: {[], 0}

  defp layout_orphans(orphans, start_x, start_y) do
    # Label
    label = [
      ~s[<text x="#{start_x}" y="#{start_y - 8}" fill="#{@dim_text}" font-size="11" font-family="monospace">Standalone processes:</text>]
    ]

    {elements, _x_cursor} =
      Enum.reduce(orphans, {[], start_x}, fn process, {elems, x} ->
        box = render_process_box(process, x, start_y)
        {[box | elems], x + @process_w + @child_gap_x}
      end)

    {label ++ List.flatten(Enum.reverse(elements)), @process_h + 30}
  end

  defp layout_messages(topology, _start_x, _start_y) do
    # For now, render message relationships as annotations
    # Full wire routing between arbitrary positioned boxes requires
    # a second layout pass — we show the relationships as a summary
    inter_process =
      topology
      |> Enum.flat_map(fn p ->
        p.outgoing_messages
        |> Enum.filter(fn m -> m.to != :unknown end)
        |> Enum.map(fn m -> {p.module, m.to, m.type, m.function} end)
      end)
      |> Enum.uniq()

    case inter_process do
      [] ->
        []

      messages ->
        # Render as a text summary at the bottom
        [
          ~s(<text x="#{@margin}" y="#{@margin}" fill="#{@dim_text}" font-size="10" font-family="monospace" opacity="0">Messages: #{length(messages)}</text>)
        ]
    end
  end

  # --- Process box rendering ---

  defp render_process_box(process, x, y) do
    accent = accent_color(process.type)
    type_icon = type_icon(process.type)
    mod_name = AST.short_name(process.module)

    incoming_count = length(process.incoming_messages)
    outgoing_count = length(process.outgoing_messages)

    [
      # Box
      ~s(<rect x="#{x}" y="#{y}" width="#{@process_w}" height="#{@process_h}" rx="6" fill="#{@process_bg}" stroke="#{accent}" stroke-width="1.5"/>),

      # Type icon + name
      ~s(<text x="#{x + 28}" y="#{y + 22}" fill="#{accent}" font-size="12" font-weight="600" font-family="monospace">#{type_icon} #{mod_name}</text>),

      # Full module name
      ~s(<text x="#{x + 10}" y="#{y + 40}" fill="#{@dim_text}" font-size="9" font-family="monospace">#{AST.module_name(process.module)}</text>),

      # Mailbox in (top-left corner)
      render_mailbox_in(x - 4, y - 4),

      # Incoming count badge
      render_badge(x + @mailbox_size - 2, y - 2, incoming_count, @mailbox_in),

      # Outbox (bottom-right corner)
      render_mailbox_out(x + @process_w - @mailbox_size + 4, y + @process_h - @mailbox_size + 4),

      # Outgoing count badge
      render_badge(x + @process_w + 2, y + @process_h - 4, outgoing_count, @mailbox_out)
    ]
  end

  # Mailbox (incoming) — small envelope icon at top-left
  defp render_mailbox_in(x, y) do
    ms = @mailbox_size
    mid = ms / 2

    Enum.join(
      [
        ~s[<g transform="translate(#{x},#{y})">],
        ~s[<rect width="#{ms}" height="#{ms}" rx="2" fill="#{@mailbox_in}" opacity="0.15" stroke="#{@mailbox_in}" stroke-width="0.8"/>],
        ~s[<path d="M 2 4 L #{mid} #{ms - 3} L #{ms - 2} 4" fill="none" stroke="#{@mailbox_in}" stroke-width="1.2" stroke-linecap="round"/>],
        ~s[<line x1="2" y1="3" x2="#{ms - 2}" y2="3" stroke="#{@mailbox_in}" stroke-width="0.8"/>],
        ~s[</g>]
      ],
      "\n"
    )
  end

  # Outbox (outgoing) — small envelope icon at bottom-right
  defp render_mailbox_out(x, y) do
    ms = @mailbox_size

    Enum.join(
      [
        ~s[<g transform="translate(#{x},#{y})">],
        ~s[<rect width="#{ms}" height="#{ms}" rx="2" fill="#{@mailbox_out}" opacity="0.15" stroke="#{@mailbox_out}" stroke-width="0.8"/>],
        ~s[<path d="M 2 #{ms - 4} L #{ms / 2} 3 L #{ms - 2} #{ms - 4}" fill="none" stroke="#{@mailbox_out}" stroke-width="1.2" stroke-linecap="round"/>],
        ~s[<line x1="2" y1="#{ms - 3}" x2="#{ms - 2}" y2="#{ms - 3}" stroke="#{@mailbox_out}" stroke-width="0.8"/>],
        ~s[</g>]
      ],
      "\n"
    )
  end

  defp render_badge(_x, _y, 0, _color), do: ""

  defp render_badge(x, y, count, color) do
    Enum.join(
      [
        ~s[<circle cx="#{x}" cy="#{y}" r="7" fill="#{color}" opacity="0.9"/>],
        ~s[<text x="#{x}" y="#{y + 3.5}" text-anchor="middle" fill="#{@bg}" font-size="8" font-weight="700" font-family="monospace">#{count}</text>]
      ],
      "\n"
    )
  end

  defp render_legend(x, y) do
    [
      ~s[<g transform="translate(#{x},#{y})" opacity="0.7">],
      ~s[  <rect width="250" height="70" rx="4" fill="#{@process_bg}" stroke="#{@process_border}" stroke-width="0.5"/>],
      ~s[  <text x="8" y="14" fill="#{@dim_text}" font-size="9" font-family="monospace">Legend:</text>],
      ~s[  <rect x="8" y="20" width="10" height="10" rx="2" fill="#{@mailbox_in}" opacity="0.3" stroke="#{@mailbox_in}" stroke-width="0.5"/>],
      ~s[  <text x="22" y="29" fill="#{@dim_text}" font-size="9" font-family="monospace">Incoming mailbox - top-left</text>],
      ~s[  <rect x="8" y="34" width="10" height="10" rx="2" fill="#{@mailbox_out}" opacity="0.3" stroke="#{@mailbox_out}" stroke-width="0.5"/>],
      ~s[  <text x="22" y="43" fill="#{@dim_text}" font-size="9" font-family="monospace">Outgoing queue - bottom-right</text>],
      ~s[  <rect x="8" y="48" width="10" height="10" rx="2" fill="none" stroke="#{@supervisor_accent}" stroke-width="1" stroke-dasharray="3,2"/>],
      ~s[  <text x="22" y="57" fill="#{@dim_text}" font-size="9" font-family="monospace">Supervisor frame - contains children</text>],
      ~s[</g>]
    ]
  end

  # --- Messaging-only diagram ---

  defp render_messaging_diagram(topology) do
    process_count = length(topology)
    cols = min(process_count, 4)
    rows = ceil(process_count / cols)

    total_w = cols * (@process_w + 40) + @margin * 2
    total_h = rows * (@process_h + 60) + @margin * 2 + 40

    # Position processes in a grid
    positions =
      topology
      |> Enum.with_index()
      |> Map.new(fn {p, idx} ->
        col = rem(idx, cols)
        row = div(idx, cols)
        x = @margin + col * (@process_w + 40)
        y = @margin + 30 + row * (@process_h + 60)
        {p.module, {x, y}}
      end)

    # Process boxes
    process_elements =
      Enum.flat_map(topology, fn p ->
        {x, y} = Map.get(positions, p.module, {0, 0})
        render_process_box(p, x, y)
      end)

    # Message wires
    wire_elements = Enum.flat_map(topology, &wire_elements_for_process(&1, positions))

    title = [
      ~s(<text x="#{@margin}" y="24" fill="#{@text_color}" font-size="14" font-weight="600" font-family="monospace">OTP Process Messaging</text>)
    ]

    all = title ++ render_legend(total_w - 260, 8) ++ process_elements ++ wire_elements
    DiagramHelpers.wrap_svg(all, total_w, total_h)
  end

  defp no_otp_svg do
    DiagramHelpers.wrap_svg(
      [
        ~s(<text x="40" y="40" fill="#{@dim_text}" font-size="14" font-family="monospace">No OTP processes detected in compiled beams.</text>)
      ],
      500,
      80
    )
  end

  # --- Helpers ---

  defp wire_elements_for_process(p, positions) do
    p.outgoing_messages
    |> Enum.filter(fn m -> m.to != :unknown and Map.has_key?(positions, m.to) end)
    |> Enum.flat_map(&wire_segment(&1, p.module, positions))
  end

  defp wire_segment(m, from_module, positions) do
    {from_x, from_y} = Map.get(positions, from_module, {0, 0})
    {to_x, to_y} = Map.get(positions, m.to, {0, 0})

    fx = from_x + @process_w - 4
    fy = from_y + @process_h - 4
    tx = to_x + 4
    ty = to_y + 4
    mid_x = (fx + tx) / 2
    color = wire_color(m.type)

    [
      ~s(<path d="M #{fx} #{fy} C #{mid_x} #{fy}, #{mid_x} #{ty}, #{tx} #{ty}" fill="none" stroke="#{color}" stroke-width="1.5" stroke-dasharray="4,3" opacity="0.6"/>),
      ~s(<circle cx="#{tx}" cy="#{ty}" r="3" fill="#{color}" opacity="0.8"/>)
    ]
  end

  defp wire_color(:call), do: @genserver_accent
  defp wire_color(:cast), do: @agent_accent
  defp wire_color(:send), do: @task_accent

  defp accent_color(:supervisor), do: @supervisor_accent
  defp accent_color(:genserver), do: @genserver_accent
  defp accent_color(:agent), do: @agent_accent
  defp accent_color(:task), do: @task_accent
  defp accent_color(:gen_statem), do: @genserver_accent
  defp accent_color(_), do: @process_border

  defp type_icon(:supervisor), do: "⬡"
  defp type_icon(:genserver), do: "◆"
  defp type_icon(:agent), do: "●"
  defp type_icon(:task), do: "▶"
  defp type_icon(:gen_statem), do: "◈"
  defp type_icon(_), do: "○"
end
