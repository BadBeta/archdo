defmodule Archdo.Compiled.DiagramInteractive do
  @moduledoc false

  alias Archdo.AST
  alias Archdo.Compiled.Graph

  @doc """
  Generate an interactive HTML file with LabVIEW-style architecture visualization.
  The file is self-contained — no external dependencies, opens in any browser.
  """
  def generate(%Graph{} = graph) do
    contexts = Graph.discover_contexts(graph)
    graph_json = build_graph_json(graph, contexts)

    html_template(graph_json)
  end

  defp build_graph_json(graph, contexts) do
    nodes = build_nodes(graph, contexts)
    edges = build_edges(graph, nodes)
    context_groups = build_context_groups(contexts)

    Jason.encode!(%{
      nodes: nodes,
      edges: edges,
      contexts: context_groups
    })
  end

  defp elixir_module?(mod) when is_atom(mod), do: String.starts_with?(Atom.to_string(mod), "Elixir.")
  defp elixir_module?(_), do: false

  defp safe_short_name(mod) do
    case elixir_module?(mod) do
      true -> AST.short_name(mod)
      false -> Atom.to_string(mod)
    end
  end

  defp build_nodes(graph, contexts) do
    membership = Graph.build_context_membership(contexts)

    graph.modules
    |> Enum.filter(fn {mod, _} -> elixir_module?(mod) end)
    |> Enum.map(fn {mod, info} ->
      mod_name = AST.module_name(mod)
      short = safe_short_name(mod)
      ctx = Map.get(membership, mod, "Uncategorized")

      # Build input ports (functions called BY this module from others)
      deps = Graph.module_dependencies(graph, mod)
      inputs =
        deps
        |> Enum.take(12)
        |> Enum.map(fn dep_mod ->
          dep_name = safe_short_name(dep_mod)
          %{name: dep_name, module: AST.module_name(dep_mod), type: "dependency"}
        end)

      # Build output ports (this module's exports called by others)
      exports =
        info.exports
        |> Enum.reject(fn {name, _} ->
          name in [:__struct__, :__schema__, :__changeset__, :__impl__, :__protocol__,
                   :__info__, :__using__, :behaviour_info, :module_info]
        end)
        |> Enum.take(15)
        |> Enum.map(fn {name, arity} ->
          callers = Graph.callers_of(graph, {mod, name, arity})
          external = Enum.reject(callers, fn c -> elem(c.caller, 0) == mod end)
          %{name: "#{name}/#{arity}", callers: length(external), type: "export"}
        end)

      layer = classify_layer(mod_name, info)

      %{
        id: mod_name,
        short: short,
        context: ctx,
        layer: layer,
        inputs: inputs,
        outputs: exports,
        behaviours: Enum.map(info.behaviours, &AST.module_name/1),
        struct_fields: info.struct_fields
      }
    end)
  end

  defp build_edges(graph, nodes) do
    node_ids = MapSet.new(Enum.map(nodes, & &1.id))

    graph.calls
    |> Enum.map(fn call ->
      caller_mod = AST.module_name(elem(call.caller, 0))
      callee_mod = AST.module_name(elem(call.callee, 0))
      {_, caller_fn, caller_arity} = call.caller
      {_, callee_fn, callee_arity} = call.callee

      %{
        from: caller_mod,
        to: callee_mod,
        from_port: "#{caller_fn}/#{caller_arity}",
        to_port: "#{callee_fn}/#{callee_arity}"
      }
    end)
    |> Enum.filter(fn e -> e.from in node_ids and e.to in node_ids and e.from != e.to end)
    |> Enum.uniq_by(fn e -> {e.from, e.to} end)
  end

  defp build_context_groups(contexts) do
    Enum.map(contexts, fn ctx ->
      %{
        name: ctx.context,
        members: Enum.map(ctx.members, &AST.module_name/1),
        cohesion: ctx.cohesion,
        coupling: ctx.coupling
      }
    end)
  end

  defp classify_layer(mod_name, info) do
    cond do
      String.contains?(mod_name, "Controller") or String.contains?(mod_name, "Live") or
        String.contains?(mod_name, "Channel") or String.contains?(mod_name, "Router") or
        String.contains?(mod_name, "Endpoint") or String.contains?(mod_name, "Plug") ->
        "interface"

      String.contains?(mod_name, "Repo") or String.contains?(mod_name, "Mailer") or
        String.contains?(mod_name, "Adapter") or String.contains?(mod_name, "Client") ->
        "infrastructure"

      Enum.any?(info.behaviours, &(&1 in [Supervisor, GenServer, Agent, :gen_statem])) ->
        "otp"

      true ->
        "domain"
    end
  end

  # --- HTML Template ---

  defp html_template(graph_json) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <title>Archdo — Interactive Architecture Diagram</title>
    <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { background: #1a1a2e; overflow: hidden; font-family: 'JetBrains Mono', 'Fira Code', 'Consolas', monospace; }
    #canvas { width: 100vw; height: 100vh; }
    svg { width: 100%; height: 100%; }

    /* Module node styles */
    .node-frame { cursor: pointer; }
    .node-frame:hover .node-bg { filter: brightness(1.2); }
    .node-bg { rx: 6; ry: 6; }
    .node-title { font-size: 11px; font-weight: 600; fill: #fff; }
    .port-label { font-size: 8px; fill: #a0a0b0; }
    .port-dot { r: 4; stroke-width: 1.5; }
    .port-dot.input { fill: #4CAF50; stroke: #2E7D32; }
    .port-dot.output { fill: #FF9800; stroke: #E65100; }
    .port-dot.unconnected { fill: #555; stroke: #333; }

    /* Wire styles */
    .wire { fill: none; stroke-width: 1.5; opacity: 0.6; }
    .wire:hover { opacity: 1; stroke-width: 2.5; }
    .wire.ok-error { stroke: #4CAF50; }
    .wire.data { stroke: #42A5F5; }
    .wire.otp { stroke: #AB47BC; }
    .wire.default { stroke: #78909C; }

    /* Bridge for wire crossings */
    .bridge { fill: #1a1a2e; stroke: none; }

    /* Context group */
    .context-bg { fill: rgba(255,255,255,0.03); stroke: rgba(255,255,255,0.08); stroke-width: 1; rx: 12; }
    .context-label { font-size: 13px; fill: rgba(255,255,255,0.4); font-weight: 300; }

    /* Layer labels */
    .layer-label { font-size: 10px; fill: rgba(255,255,255,0.2); letter-spacing: 2px; text-transform: uppercase; }

    /* Detail panel */
    #detail-panel {
      position: fixed; right: 20px; top: 20px; width: 350px;
      background: #16213e; border: 1px solid #333; border-radius: 8px;
      padding: 16px; color: #e0e0e0; font-size: 12px;
      display: none; max-height: 80vh; overflow-y: auto;
      box-shadow: 0 8px 32px rgba(0,0,0,0.5);
    }
    #detail-panel h2 { font-size: 16px; color: #fff; margin-bottom: 8px; }
    #detail-panel h3 { font-size: 12px; color: #888; margin: 12px 0 4px; text-transform: uppercase; letter-spacing: 1px; }
    #detail-panel .port-list { list-style: none; }
    #detail-panel .port-list li { padding: 2px 0; font-size: 11px; }
    #detail-panel .port-list li .connected { color: #4CAF50; }
    #detail-panel .port-list li .unconnected { color: #555; }
    #detail-panel .close { position: absolute; top: 8px; right: 12px; cursor: pointer; color: #666; font-size: 18px; }
    #detail-panel .close:hover { color: #fff; }
    #detail-panel .badge { display: inline-block; padding: 1px 6px; border-radius: 3px; font-size: 10px; margin-left: 4px; }
    #detail-panel .badge.interface { background: #1565C0; }
    #detail-panel .badge.domain { background: #2E7D32; }
    #detail-panel .badge.infrastructure { background: #BF360C; }
    #detail-panel .badge.otp { background: #6A1B9A; }

    /* Controls */
    #controls {
      position: fixed; left: 20px; bottom: 20px; color: #666; font-size: 11px;
    }
    #controls kbd { background: #333; padding: 1px 5px; border-radius: 3px; color: #aaa; }

    /* Layer colors */
    .layer-interface .node-bg { fill: #1a237e; stroke: #3949ab; }
    .layer-domain .node-bg { fill: #1b3a1b; stroke: #388E3C; }
    .layer-infrastructure .node-bg { fill: #3e1a1a; stroke: #c62828; }
    .layer-otp .node-bg { fill: #2a1a3e; stroke: #7B1FA2; }
    </style>
    </head>
    <body>
    <div id="canvas">
      <svg id="diagram" xmlns="http://www.w3.org/2000/svg">
        <defs>
          <marker id="arrowhead" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
            <polygon points="0 0, 8 3, 0 6" fill="#78909C" opacity="0.5"/>
          </marker>
        </defs>
        <g id="viewport"></g>
      </svg>
    </div>

    <div id="detail-panel">
      <span class="close" onclick="closeDetail()">&times;</span>
      <div id="detail-content"></div>
    </div>

    <div id="controls">
      <kbd>Scroll</kbd> zoom &nbsp; <kbd>Drag</kbd> pan &nbsp; <kbd>Click</kbd> module details &nbsp; <kbd>Esc</kbd> close panel
    </div>

    <script>
    const DATA = #{graph_json};

    // --- Layout Engine ---
    const NODE_W = 180, NODE_H_BASE = 40, PORT_H = 14, PORT_R = 4;
    const MARGIN = 60, COL_GAP = 100, ROW_GAP = 30;
    const CONTEXT_PAD = 20;

    function layout(data) {
      const nodes = new Map();
      const contextGroups = new Map();

      // Group by context
      data.nodes.forEach(n => {
        if (!contextGroups.has(n.context)) contextGroups.set(n.context, []);
        contextGroups.get(n.context).push(n);
      });

      // Layout contexts in columns
      let cx = MARGIN;
      const contextPositions = [];

      contextGroups.forEach((members, ctxName) => {
        let cy = MARGIN + 30;  // Leave room for context label
        const ctxX = cx;
        let maxW = 0;

        members.forEach(n => {
          const nPorts = Math.max(n.inputs.length, n.outputs.length, 1);
          const h = NODE_H_BASE + nPorts * PORT_H;
          const w = NODE_W;

          nodes.set(n.id, {
            ...n, x: cx + CONTEXT_PAD, y: cy, w, h,
            inputPorts: buildPorts(n.inputs, cx + CONTEXT_PAD, cy, h, 'input', w),
            outputPorts: buildPorts(n.outputs, cx + CONTEXT_PAD, cy, h, 'output', w)
          });

          cy += h + ROW_GAP;
          maxW = Math.max(maxW, w);
        });

        const ctxW = maxW + CONTEXT_PAD * 2;
        const ctxH = cy - MARGIN - 30 + CONTEXT_PAD;
        contextPositions.push({ name: ctxName, x: ctxX, y: MARGIN, w: ctxW, h: ctxH });

        cx += ctxW + COL_GAP;
      });

      return { nodes, contextPositions, totalW: cx, totalH: 4000 };
    }

    function buildPorts(ports, nx, ny, nh, type, nw) {
      if (ports.length === 0) return [];
      const spacing = Math.min(PORT_H, (nh - 20) / ports.length);
      const startY = ny + 20;

      return ports.map((p, i) => ({
        ...p,
        x: type === 'input' ? nx : nx + nw,
        y: startY + i * spacing + spacing / 2,
        type
      }));
    }

    // --- SVG Rendering ---
    function render(layoutData) {
      const vp = document.getElementById('viewport');
      vp.innerHTML = '';

      const { nodes, contextPositions } = layoutData;

      // Draw context backgrounds
      contextPositions.forEach(ctx => {
        const g = svgEl('g');
        g.appendChild(svgRect(ctx.x, ctx.y, ctx.w, ctx.h, 'context-bg'));
        const label = svgText(ctx.x + 12, ctx.y + 18, ctx.name, 'context-label');
        g.appendChild(label);
        vp.appendChild(g);
      });

      // Draw wires first (behind nodes)
      const wireGroup = svgEl('g', { id: 'wires' });
      DATA.edges.forEach(edge => {
        const fromNode = nodes.get(edge.from);
        const toNode = nodes.get(edge.to);
        if (!fromNode || !toNode) return;

        const x1 = fromNode.x + fromNode.w;
        const y1 = fromNode.y + fromNode.h / 2;
        const x2 = toNode.x;
        const y2 = toNode.y + toNode.h / 2;

        const midX = (x1 + x2) / 2;
        const path = `M ${x1} ${y1} C ${midX} ${y1}, ${midX} ${y2}, ${x2} ${y2}`;

        const wire = svgEl('path', {
          d: path, class: 'wire default',
          'marker-end': 'url(#arrowhead)'
        });
        wire.setAttribute('data-from', edge.from);
        wire.setAttribute('data-to', edge.to);
        wireGroup.appendChild(wire);
      });
      vp.appendChild(wireGroup);

      // Draw nodes
      nodes.forEach((n, id) => {
        const g = svgEl('g', { class: `node-frame layer-${n.layer}`, 'data-id': id });
        g.setAttribute('transform', `translate(0,0)`);

        // Background
        g.appendChild(svgRect(n.x, n.y, n.w, n.h, 'node-bg'));

        // Title (truncate to fit)
        const titleText = n.short.length > 20 ? n.short.slice(0, 18) + '..' : n.short;
        g.appendChild(svgText(n.x + 8, n.y + 14, titleText, 'node-title'));

        // Input ports (left side)
        n.inputPorts.forEach(p => {
          g.appendChild(svgCircle(p.x, p.y, PORT_R, 'port-dot input'));
          g.appendChild(svgText(p.x + 8, p.y + 3, p.name, 'port-label'));
        });

        // Output ports (right side)
        n.outputPorts.forEach(p => {
          const connected = p.callers > 0;
          g.appendChild(svgCircle(p.x, p.y, PORT_R,
            'port-dot ' + (connected ? 'output' : 'unconnected')));
          const label = svgText(p.x - 8, p.y + 3, p.name, 'port-label');
          label.setAttribute('text-anchor', 'end');
          g.appendChild(label);
        });

        g.addEventListener('click', () => showDetail(n));
        vp.appendChild(g);
      });
    }

    // --- SVG Helpers ---
    function svgEl(tag, attrs = {}) {
      const el = document.createElementNS('http://www.w3.org/2000/svg', tag);
      Object.entries(attrs).forEach(([k, v]) => el.setAttribute(k, v));
      return el;
    }

    function svgRect(x, y, w, h, cls) {
      return svgEl('rect', { x, y, width: w, height: h, class: cls });
    }

    function svgText(x, y, text, cls) {
      const el = svgEl('text', { x, y, class: cls });
      el.textContent = text;
      return el;
    }

    function svgCircle(cx, cy, r, cls) {
      return svgEl('circle', { cx, cy, r, class: cls });
    }

    // --- Pan & Zoom ---
    let viewX = 0, viewY = 0, zoom = 1;
    let dragging = false, lastX, lastY;

    const svg = document.getElementById('diagram');
    const vp = document.getElementById('viewport');

    function updateTransform() {
      vp.setAttribute('transform', `translate(${viewX},${viewY}) scale(${zoom})`);
    }

    svg.addEventListener('wheel', e => {
      e.preventDefault();
      const factor = e.deltaY > 0 ? 0.9 : 1.1;
      const newZoom = Math.max(0.1, Math.min(5, zoom * factor));

      // Zoom toward cursor
      const rect = svg.getBoundingClientRect();
      const mx = e.clientX - rect.left;
      const my = e.clientY - rect.top;

      viewX = mx - (mx - viewX) * (newZoom / zoom);
      viewY = my - (my - viewY) * (newZoom / zoom);
      zoom = newZoom;
      updateTransform();
    });

    svg.addEventListener('mousedown', e => {
      if (e.target.closest('.node-frame')) return;
      dragging = true;
      lastX = e.clientX;
      lastY = e.clientY;
      svg.style.cursor = 'grabbing';
    });

    svg.addEventListener('mousemove', e => {
      if (!dragging) return;
      viewX += e.clientX - lastX;
      viewY += e.clientY - lastY;
      lastX = e.clientX;
      lastY = e.clientY;
      updateTransform();
    });

    svg.addEventListener('mouseup', () => {
      dragging = false;
      svg.style.cursor = 'default';
    });

    // --- Detail Panel ---
    function showDetail(node) {
      const panel = document.getElementById('detail-panel');
      const content = document.getElementById('detail-content');

      let html = `<h2>${node.short} <span class="badge ${node.layer}">${node.layer}</span></h2>`;
      html += `<div style="color:#888;margin-bottom:8px">${node.id}</div>`;

      if (node.behaviours.length > 0) {
        html += `<h3>Behaviours</h3><div>${node.behaviours.join(', ')}</div>`;
      }

      if (node.struct_fields.length > 0) {
        html += `<h3>Struct Fields</h3><div>${node.struct_fields.join(', ')}</div>`;
      }

      html += `<h3>Inputs (Dependencies)</h3><ul class="port-list">`;
      if (node.inputs.length === 0) html += '<li style="color:#555">none</li>';
      node.inputs.forEach(p => {
        html += `<li><span class="connected">&#9679;</span> ${p.name} <span style="color:#666">(${p.module})</span></li>`;
      });
      html += '</ul>';

      html += `<h3>Outputs (Exports)</h3><ul class="port-list">`;
      if (node.outputs.length === 0) html += '<li style="color:#555">none</li>';
      node.outputs.forEach(p => {
        const cls = p.callers > 0 ? 'connected' : 'unconnected';
        html += `<li><span class="${cls}">&#9679;</span> ${p.name} <span style="color:#666">(${p.callers} callers)</span></li>`;
      });
      html += '</ul>';

      content.innerHTML = html;
      panel.style.display = 'block';
    }

    function closeDetail() {
      document.getElementById('detail-panel').style.display = 'none';
    }

    document.addEventListener('keydown', e => {
      if (e.key === 'Escape') closeDetail();
    });

    // --- Init ---
    const layoutData = layout(DATA);
    const svgEl2 = document.getElementById('diagram');
    svgEl2.setAttribute('viewBox', `0 0 ${layoutData.totalW + 100} ${layoutData.totalH}`);
    render(layoutData);

    // Fit to screen
    const screenW = window.innerWidth;
    zoom = Math.min(1, screenW / (layoutData.totalW + 200));
    updateTransform();
    </script>
    </body>
    </html>
    """
  end
end
