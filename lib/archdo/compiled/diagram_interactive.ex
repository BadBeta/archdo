defmodule Archdo.Compiled.DiagramInteractive do
  @moduledoc false

  alias Archdo.AST
  alias Archdo.Compiled.Graph

  @doc """
  Generate an interactive HTML file with two-level architecture visualization.

  Overview level: contexts as boxes with aggregated ports, context-to-context wires.
  Detail level: click a context to zoom in and see individual modules and wires.
  Boundary-crossing connections are highlighted in red.
  """
  def generate(%Graph{} = graph) do
    contexts = Graph.discover_contexts(graph)
    graph_json = build_graph_json(graph, contexts)

    html_template(graph_json)
  end

  defp build_graph_json(graph, contexts) do
    membership = Graph.build_context_membership(contexts)
    nodes = build_nodes(graph, membership)
    edges = build_edges(graph, nodes, membership)
    context_groups = build_context_groups(contexts)
    context_edges = build_context_edges(edges, nodes)

    Jason.encode!(%{
      nodes: nodes,
      edges: edges,
      contexts: context_groups,
      contextEdges: context_edges
    })
  end

  defp elixir_module?(mod) when is_atom(mod),
    do: String.starts_with?(Atom.to_string(mod), "Elixir.")

  defp elixir_module?(_), do: false

  defp safe_short_name(mod) do
    case elixir_module?(mod) do
      true -> AST.short_name(mod)
      false -> Atom.to_string(mod)
    end
  end

  defp build_nodes(graph, membership) do
    graph.modules
    |> Enum.filter(fn {mod, _} -> elixir_module?(mod) end)
    |> Enum.map(fn {mod, info} ->
      mod_name = AST.module_name(mod)
      short = safe_short_name(mod)
      ctx = Map.get(membership, mod, "Uncategorized")

      deps = Graph.module_dependencies(graph, mod)

      inputs =
        deps
        |> Enum.take(12)
        |> Enum.map(fn dep_mod ->
          dep_name = safe_short_name(dep_mod)
          dep_ctx = Map.get(membership, dep_mod, "Uncategorized")

          %{
            name: dep_name,
            module: AST.module_name(dep_mod),
            type: "dependency",
            context: dep_ctx
          }
        end)

      exports =
        info.exports
        |> Enum.reject(fn {name, _} ->
          name in [
            :__struct__,
            :__schema__,
            :__changeset__,
            :__impl__,
            :__protocol__,
            :__info__,
            :__using__,
            :behaviour_info,
            :module_info
          ]
        end)
        |> Enum.take(15)
        |> Enum.map(fn {name, arity} ->
          callers = Graph.callers_of(graph, {mod, name, arity})
          external = Enum.reject(callers, fn c -> elem(c.caller, 0) == mod end)
          %{name: "#{name}/#{arity}", callers: length(external), type: "export"}
        end)

      layer = classify_layer(mod_name, info)

      # Is this the boundary module for its context? (same name as context)
      is_boundary =
        mod
        |> Module.split()
        |> Enum.join(".") ==
          ctx

      %{
        id: mod_name,
        short: short,
        context: ctx,
        layer: layer,
        inputs: inputs,
        outputs: exports,
        behaviours: Enum.map(info.behaviours, &AST.module_name/1),
        struct_fields: info.struct_fields,
        is_boundary: is_boundary
      }
    end)
  end

  defp build_edges(graph, nodes, _membership) do
    node_ids = MapSet.new(Enum.map(nodes, & &1.id))
    node_ctx = Map.new(nodes, fn n -> {n.id, n.context} end)

    graph.calls
    |> Enum.map(fn call ->
      caller_mod = AST.module_name(elem(call.caller, 0))
      callee_mod = AST.module_name(elem(call.callee, 0))
      {_, caller_fn, caller_arity} = call.caller
      {_, callee_fn, callee_arity} = call.callee

      from_ctx = Map.get(node_ctx, caller_mod)
      to_ctx = Map.get(node_ctx, callee_mod)
      crosses_boundary = from_ctx != nil and to_ctx != nil and from_ctx != to_ctx

      # Check if this bypasses the boundary module (callee is internal, not boundary)
      callee_node = Enum.find(nodes, fn n -> n.id == callee_mod end)

      bypasses_boundary =
        case {crosses_boundary, callee_node} do
          {true, %{is_boundary: false}} -> true
          _ -> false
        end

      %{
        from: caller_mod,
        to: callee_mod,
        from_port: "#{caller_fn}/#{caller_arity}",
        to_port: "#{callee_fn}/#{callee_arity}",
        from_context: from_ctx,
        to_context: to_ctx,
        crosses_boundary: crosses_boundary,
        bypasses_boundary: bypasses_boundary
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
        coupling: ctx.coupling,
        incoming_calls: ctx.incoming_calls,
        outgoing_calls: ctx.outgoing_calls,
        internal_calls: ctx.internal_calls,
        leak_calls: ctx.leak_calls,
        boundary_module:
          case ctx.boundary_module do
            nil -> nil
            mod -> AST.module_name(mod)
          end
      }
    end)
  end

  defp build_context_edges(edges, _nodes) do
    # Keep individual wires with port info for port-level routing
    edges
    |> Enum.filter(fn e -> e.crosses_boundary end)
    |> Enum.uniq_by(fn e -> {e.from_context, e.to_context, e.from_port, e.to_port} end)
    |> Enum.map(fn e ->
      %{
        from: e.from_context,
        to: e.to_context,
        from_port: e.from_port,
        to_port: e.to_port,
        bypasses_boundary: e.bypasses_boundary
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
    #{css()}
    </style>
    </head>
    <body>
    <div id="canvas">
      <svg id="diagram" xmlns="http://www.w3.org/2000/svg">
        <defs>
          <marker id="arrow" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
            <polygon points="0 0, 8 3, 0 6" fill="#90A4AE" opacity="0.6"/>
          </marker>
          <marker id="arrow-red" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
            <polygon points="0 0, 8 3, 0 6" fill="#E53935" opacity="0.7"/>
          </marker>
        </defs>
        <g id="viewport"></g>
      </svg>
    </div>

    <div id="toolbar">
      <button id="btn-fit" onclick="zoomToFit()">&#x2922; Fit All</button>
      <button id="btn-back" onclick="showOverview()" style="display:none">&#x2190; Overview</button>
      <span id="view-label">Overview</span>
    </div>

    <div id="info-panel">
      <div id="info-content">
        <div id="info-hint">Click a context or module to see details</div>
      </div>
    </div>

    <div id="controls">
      <kbd>Scroll</kbd> zoom &nbsp; <kbd>Drag</kbd> pan &nbsp;
      <kbd>Click</kbd> context to zoom in &nbsp; <kbd>F</kbd> fit all &nbsp;
      <kbd>Esc</kbd> back / deselect
    </div>

    <script>
    const DATA = #{graph_json};
    #{javascript()}
    </script>
    </body>
    </html>
    """
  end

  defp css do
    ~S"""
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      background: #f5f6fa; overflow: hidden;
      font-family: 'Inter', 'Segoe UI', system-ui, -apple-system, sans-serif;
      color: #333;
    }
    #canvas { width: 100vw; height: 100vh; }
    svg { width: 100%; height: 100%; }

    /* --- Context boxes (overview) --- */
    .ctx-frame { cursor: pointer; }
    .ctx-frame:hover .ctx-bg { filter: brightness(0.96); }
    .ctx-bg { rx: 12; ry: 12; stroke-width: 2; }
    .ctx-bg.normal { fill: #fff; stroke: #cfd8dc; }
    .ctx-bg.has-leak { fill: #fff5f5; stroke: #ef9a9a; }
    .ctx-title { font-size: 14px; font-weight: 700; fill: #263238; }
    .ctx-subtitle { font-size: 10px; fill: #78909c; }
    .ctx-stats { font-size: 9px; fill: #90a4ae; }

    /* Ports on context and module boxes */
    .port-dot { stroke-width: 1.5; }
    .port-dot.in { fill: #66BB6A; stroke: #43A047; }
    .port-dot.out { fill: #42A5F5; stroke: #1E88E5; }
    .port-dot.unconnected { fill: #ccc; stroke: #aaa; }
    .port-label { font-size: 7.5px; fill: #78909c; }

    /* --- Module nodes (detail view) --- */
    .node-frame { cursor: pointer; }
    .node-frame:hover .node-bg { filter: brightness(0.96); }
    .node-bg { rx: 6; ry: 6; }
    .node-title { font-size: 11px; font-weight: 600; }
    .node-title.boundary { fill: #1565C0; }
    .node-title.internal { fill: #37474F; }

    /* Layer colors */
    .layer-interface .node-bg { fill: #E3F2FD; stroke: #64B5F6; }
    .layer-domain .node-bg { fill: #E8F5E9; stroke: #81C784; }
    .layer-infrastructure .node-bg { fill: #FBE9E7; stroke: #EF9A9A; }
    .layer-otp .node-bg { fill: #F3E5F5; stroke: #CE93D8; }

    /* --- Wires --- */
    .wire { fill: none; stroke-width: 1.5; opacity: 0.35; }
    .wire:hover { opacity: 0.7; stroke-width: 2.5; }
    .wire.normal { stroke: #78909C; }
    .wire.cross-boundary { stroke: #78909C; stroke-dasharray: 6 3; }
    .wire.bypass { stroke: #E53935; stroke-width: 2; opacity: 0.65; }

    /* Highlighted wires */
    .wire-highlight { fill: none; stroke-width: 3; opacity: 1; pointer-events: none; }
    .wire-highlight.outgoing { stroke: #42A5F5; }
    .wire-highlight.incoming { stroke: #66BB6A; }
    .wire-highlight.violation { stroke: #E53935; }

    /* Dimmed state */
    .dimmed .ctx-frame { opacity: 0.12; }
    .dimmed .node-frame { opacity: 0.12; }
    .dimmed .wire { opacity: 0.04; }
    .dimmed .ctx-frame.highlighted,
    .dimmed .node-frame.highlighted { opacity: 1; }
    .dimmed .ctx-frame.selected,
    .dimmed .node-frame.selected { opacity: 1; }
    .ctx-frame.selected .ctx-bg { stroke: #FFA726; stroke-width: 3; }
    .node-frame.selected .node-bg { stroke: #FFA726; stroke-width: 3; }

    /* --- Info sidebar (always present on right) --- */
    #info-panel {
      position: fixed; right: 0; top: 0; width: 320px; height: 100vh;
      background: #fff; border-left: 1px solid #e0e0e0;
      padding: 16px; font-size: 12px; overflow-y: auto;
      box-shadow: -2px 0 12px rgba(0,0,0,0.04);
    }
    #info-panel h2 { font-size: 15px; color: #263238; margin-bottom: 6px; }
    #info-panel h3 {
      font-size: 10px; color: #90a4ae; margin: 12px 0 3px;
      text-transform: uppercase; letter-spacing: 1px;
    }
    #info-panel .port-list { list-style: none; padding: 0; }
    #info-panel .port-list li { padding: 2px 0; font-size: 11px; color: #546e7a; }
    #info-panel .badge {
      display: inline-block; padding: 1px 8px; border-radius: 10px;
      font-size: 9px; margin-left: 4px; color: #fff; font-weight: 600;
    }
    #info-panel .badge.interface { background: #42A5F5; }
    #info-panel .badge.domain { background: #66BB6A; }
    #info-panel .badge.infrastructure { background: #EF5350; }
    #info-panel .badge.otp { background: #AB47BC; }
    .stat-row { display: flex; justify-content: space-between; padding: 2px 0; font-size: 11px; }
    .stat-label { color: #90a4ae; }
    .stat-value { color: #37474F; font-weight: 600; }
    .stat-value.warn { color: #E53935; }
    .member-list { list-style: none; padding: 0; }
    .member-list li { padding: 2px 0; font-size: 10px; color: #546e7a; cursor: default; }
    .member-list li .boundary-tag { color: #1565C0; font-weight: 600; font-size: 9px; margin-left: 4px; }
    #info-hint { color: #bbb; font-size: 12px; margin-top: 40px; text-align: center; }

    /* --- Toolbar --- */
    #toolbar {
      position: fixed; left: 20px; top: 20px; display: flex; gap: 8px; align-items: center; z-index: 10;
    }
    #toolbar button {
      background: #fff; border: 1px solid #cfd8dc; color: #37474F;
      padding: 8px 14px; border-radius: 8px; cursor: pointer;
      font-size: 12px; font-family: inherit; font-weight: 500;
      box-shadow: 0 1px 3px rgba(0,0,0,0.06);
    }
    #toolbar button:hover { background: #f0f0f0; border-color: #90a4ae; }
    #view-label { font-size: 13px; color: #78909c; font-weight: 500; margin-left: 8px; }

    /* --- Controls --- */
    #controls {
      position: fixed; left: 20px; bottom: 20px; color: #90a4ae; font-size: 11px; z-index: 10;
    }
    #controls kbd {
      background: #e8eaf0; padding: 1px 5px; border-radius: 3px;
      color: #546e7a; font-size: 10px;
    }
    """
  end

  defp javascript do
    ~S"""
    // ================================================================
    // DATA INDEXES
    // ================================================================
    const nodeMap = new Map(DATA.nodes.map(n => [n.id, n]));
    const ctxMap = new Map(DATA.contexts.map(c => [c.name, c]));
    const PANEL_W = 320;

    // ================================================================
    // STATE
    // ================================================================
    let currentView = 'overview';
    let currentContext = null;
    let viewX = 0, viewY = 0, zoom = 1;
    let dragging = false, lastX, lastY;

    // ================================================================
    // SVG HELPERS
    // ================================================================
    function se(tag, attrs = {}) {
      const el = document.createElementNS('http://www.w3.org/2000/svg', tag);
      Object.entries(attrs).forEach(([k, v]) => el.setAttribute(k, v));
      return el;
    }
    function sr(x, y, w, h, cls) { return se('rect', { x, y, width: w, height: h, class: cls }); }
    function st(x, y, text, cls) { const el = se('text', { x, y, class: cls }); el.textContent = text; return el; }
    function sc(cx, cy, r, cls) { return se('circle', { cx, cy, r, class: cls }); }

    // ================================================================
    // LAYERED LAYOUT — cycle-breaking + longest-path column assignment
    // Ensures maximum left-to-right flow, even with cycles.
    // ================================================================
    function topoColumns(ids, edges) {
      const idSet = new Set(ids);

      // 1. Build adjacency from edges, filtering to known ids
      const fwd = new Map();  // id → Set of targets
      const edgeCount = new Map(); // "from→to" → count (for cycle-breaking heuristic)
      ids.forEach(id => fwd.set(id, new Set()));
      edges.forEach(({from, to}) => {
        if (idSet.has(from) && idSet.has(to) && from !== to) {
          fwd.get(from).add(to);
          const key = from + '\0' + to;
          edgeCount.set(key, (edgeCount.get(key) || 0) + 1);
        }
      });

      // 2. DFS cycle-breaking: identify back-edges and reverse the lighter direction
      //    This makes the graph acyclic so Kahn's covers all nodes.
      const WHITE = 0, GRAY = 1, BLACK = 2;
      const color = new Map();
      ids.forEach(id => color.set(id, WHITE));
      const backEdges = []; // [from, to] pairs to reverse

      function dfs(u) {
        color.set(u, GRAY);
        for (const v of fwd.get(u)) {
          if (color.get(v) === GRAY) {
            // Back-edge found: u→v creates a cycle. Reverse the lighter direction.
            const fwdKey = u + '\0' + v;
            const revKey = v + '\0' + u;
            const fwdCount = edgeCount.get(fwdKey) || 0;
            const revCount = edgeCount.get(revKey) || 0;
            // Reverse the direction with fewer calls (keep the dominant flow)
            if (fwdCount <= revCount) {
              backEdges.push([u, v]);
            } else {
              backEdges.push([v, u]);
            }
          } else if (color.get(v) === WHITE) {
            dfs(v);
          }
        }
        color.set(u, BLACK);
      }
      ids.forEach(id => { if (color.get(id) === WHITE) dfs(id); });

      // Apply reversals to get a DAG
      backEdges.forEach(([from, to]) => {
        fwd.get(from).delete(to);
        fwd.get(to).add(from);
      });

      // 3. Kahn's BFS on the now-acyclic graph — longest-path layering
      const inDeg = new Map();
      ids.forEach(id => inDeg.set(id, 0));
      ids.forEach(id => {
        for (const t of fwd.get(id)) {
          inDeg.set(t, inDeg.get(t) + 1);
        }
      });

      const columns = new Map();
      let queue = ids.filter(id => inDeg.get(id) === 0);
      let col = 0;
      const visited = new Set();

      while (queue.length > 0) {
        const next = [];
        queue.forEach(id => { columns.set(id, col); visited.add(id); });
        queue.forEach(id => {
          for (const t of fwd.get(id)) {
            inDeg.set(t, inDeg.get(t) - 1);
            if (inDeg.get(t) === 0 && !visited.has(t)) next.push(t);
          }
        });
        queue = next;
        col++;
      }

      // 4. Safety net: any still-unvisited node (shouldn't happen after cycle-breaking)
      ids.forEach(id => { if (!columns.has(id)) columns.set(id, col); });

      // 5. Optional: push nodes right to their latest valid column
      //    (longest incoming path, not earliest). This clusters consumers
      //    closer to their producers and shortens wire lengths.
      const maxCol = col;
      const rev = new Map(); // id → Set of predecessors
      ids.forEach(id => rev.set(id, new Set()));
      ids.forEach(id => {
        for (const t of fwd.get(id)) rev.get(t).add(id);
      });

      // For each node, its column must be > max(predecessor columns).
      // Walk in topological order and push to max(pred) + 1.
      // Then walk reverse to pull nodes left if they have no successors at their level.
      const topoOrder = [...columns.entries()].sort((a, b) => a[1] - b[1]).map(e => e[0]);
      topoOrder.forEach(id => {
        let maxPred = -1;
        for (const p of rev.get(id)) {
          const pc = columns.get(p);
          if (pc !== undefined && pc > maxPred) maxPred = pc;
        }
        if (maxPred >= 0) columns.set(id, maxPred + 1);
      });

      return columns;
    }

    // ================================================================
    // OVERVIEW LAYOUT — topological column ordering
    // ================================================================
    const CTX_W = 240, CTX_HEADER = 50, CTX_PORT_SP = 16, CTX_COL_GAP = 160, CTX_ROW_GAP = 40, CTX_MARGIN = 50;

    function collectCtxPorts(ctxName, dir) {
      const ports = new Set();
      DATA.contextEdges.filter(e => (dir === 'in' ? e.to : e.from) === ctxName)
        .forEach(e => ports.add(dir === 'in' ? e.to_port : e.from_port));
      return [...ports].slice(0, 12);
    }

    function layoutOverview() {
      const ctxNames = DATA.contexts.map(c => c.name);
      // Build context-level edges for topological sort
      const ctxEdges = [];
      const seen = new Set();
      DATA.contextEdges.forEach(e => {
        const key = e.from + '→' + e.to;
        if (!seen.has(key)) { seen.add(key); ctxEdges.push({from: e.from, to: e.to}); }
      });
      const colMap = topoColumns(ctxNames, ctxEdges);

      // Group contexts by column
      const byCol = new Map();
      ctxNames.forEach(name => {
        const c = colMap.get(name) || 0;
        if (!byCol.has(c)) byCol.set(c, []);
        byCol.get(c).push(name);
      });

      const layouts = new Map();
      const sortedCols = [...byCol.keys()].sort((a, b) => a - b);

      let cx = CTX_MARGIN;
      sortedCols.forEach(col => {
        const names = byCol.get(col);
        let cy = CTX_MARGIN;
        let maxW = 0;

        names.forEach(name => {
          const ctx = ctxMap.get(name);
          const inP = collectCtxPorts(name, 'in');
          const outP = collectCtxPorts(name, 'out');
          const portCount = Math.max(inP.length, outP.length, 1);
          const h = CTX_HEADER + portCount * CTX_PORT_SP + 12;
          const portY0 = cy + CTX_HEADER;

          layouts.set(name, {
            ...ctx, x: cx, y: cy, w: CTX_W, h,
            inPorts: inP.map((n, i) => ({ name: n, x: cx, y: portY0 + i * CTX_PORT_SP + CTX_PORT_SP / 2 })),
            outPorts: outP.map((n, i) => ({ name: n, x: cx + CTX_W, y: portY0 + i * CTX_PORT_SP + CTX_PORT_SP / 2 }))
          });
          cy += h + CTX_ROW_GAP;
          maxW = Math.max(maxW, CTX_W);
        });
        cx += maxW + CTX_COL_GAP;
      });
      return layouts;
    }

    // ================================================================
    // RENDER OVERVIEW
    // ================================================================
    function renderOverview() {
      const vp = document.getElementById('viewport');
      vp.innerHTML = '';
      currentView = 'overview'; currentContext = null;
      document.getElementById('btn-back').style.display = 'none';
      document.getElementById('view-label').textContent = 'Overview';
      setInfo(null);

      const layouts = layoutOverview();

      // Wires — port-to-port
      const wireGroup = se('g', { id: 'wires' });
      DATA.contextEdges.forEach(edge => {
        const fc = layouts.get(edge.from), tc = layouts.get(edge.to);
        if (!fc || !tc) return;
        const outP = fc.outPorts.find(p => p.name === edge.from_port);
        const inP = tc.inPorts.find(p => p.name === edge.to_port);
        if (!outP || !inP) return;
        wireGroup.appendChild(makeWire(outP.x, outP.y, inP.x, inP.y, edge.bypasses_boundary, edge.from, edge.to));
      });
      vp.appendChild(wireGroup);
      vp.appendChild(se('g', { id: 'wire-highlights' }));

      // Context boxes
      layouts.forEach((ctx, name) => {
        const g = se('g', { class: 'ctx-frame', 'data-id': name });
        g.appendChild(sr(ctx.x, ctx.y, ctx.w, ctx.h, ctx.leak_calls > 0 ? 'ctx-bg has-leak' : 'ctx-bg normal'));
        g.appendChild(st(ctx.x + 14, ctx.y + 22, (name.split('.').slice(-1)[0] || name), 'ctx-title'));
        g.appendChild(st(ctx.x + 14, ctx.y + 38, `${ctx.members.length} modules · ${(ctx.cohesion*100).toFixed(0)}%`, 'ctx-stats'));

        ctx.inPorts.forEach(p => {
          g.appendChild(sc(p.x, p.y, 4, 'port-dot in'));
          g.appendChild(st(p.x + 8, p.y + 3, p.name, 'port-label'));
        });
        ctx.outPorts.forEach(p => {
          g.appendChild(sc(p.x, p.y, 4, 'port-dot out'));
          const lbl = st(p.x - 8, p.y + 3, p.name, 'port-label');
          lbl.setAttribute('text-anchor', 'end');
          g.appendChild(lbl);
        });

        g.addEventListener('click', e => { e.stopPropagation(); enterContext(name); });
        vp.appendChild(g);
      });
      zoomToFit();
    }

    // ================================================================
    // DETAIL LAYOUT — topological column ordering for modules
    // ================================================================
    const NODE_W = 220, NODE_H_BASE = 40, PORT_H = 16, PORT_R = 4;
    const NODE_COL_GAP = 280, NODE_ROW_GAP = 30, NODE_MARGIN = 50;

    function layoutDetail(ctxName) {
      const ctx = ctxMap.get(ctxName);
      const memberIds = new Set(ctx.members);
      const members = ctx.members.map(id => nodeMap.get(id)).filter(Boolean);

      // Collect external connected module ids
      const extIds = new Set();
      DATA.edges.forEach(e => {
        if (memberIds.has(e.from) && !memberIds.has(e.to)) extIds.add(e.to);
        if (memberIds.has(e.to) && !memberIds.has(e.from)) extIds.add(e.from);
      });

      // All ids we'll lay out
      const allIds = [...ctx.members, ...extIds];
      // Edges among all ids
      const relevantEdges = DATA.edges.filter(e => {
        const hasFrom = memberIds.has(e.from) || extIds.has(e.from);
        const hasTo = memberIds.has(e.to) || extIds.has(e.to);
        return hasFrom && hasTo && e.from !== e.to;
      });

      const colMap = topoColumns(allIds, relevantEdges);

      // Group by column
      const byCol = new Map();
      allIds.forEach(id => {
        const c = colMap.get(id) || 0;
        if (!byCol.has(c)) byCol.set(c, []);
        byCol.get(c).push(id);
      });

      const nodeLayouts = new Map();
      const sortedCols = [...byCol.keys()].sort((a, b) => a - b);

      let cx = NODE_MARGIN;
      sortedCols.forEach(col => {
        const ids = byCol.get(col);
        let cy = NODE_MARGIN;

        ids.forEach(id => {
          const n = nodeMap.get(id);
          if (!n) return;
          const isExt = extIds.has(id);
          const inputs = isExt ? n.inputs.slice(0, 4) : n.inputs;
          const outputs = isExt ? n.outputs.slice(0, 4) : n.outputs;
          const nPorts = Math.max(inputs.length, outputs.length, 1);
          const h = NODE_H_BASE + nPorts * PORT_H;

          nodeLayouts.set(id, {
            ...n, x: cx, y: cy, w: NODE_W, h, external: isExt,
            inputPorts: mkPorts(inputs, cx, cy, h, 'input', NODE_W),
            outputPorts: mkPorts(outputs, cx, cy, h, 'output', NODE_W)
          });
          cy += h + NODE_ROW_GAP;
        });
        cx += NODE_W + NODE_COL_GAP;
      });
      return nodeLayouts;
    }

    function mkPorts(ports, nx, ny, nh, type, nw) {
      if (!ports || ports.length === 0) return [];
      const spacing = Math.min(PORT_H, (nh - 20) / ports.length);
      const startY = ny + 20;
      return ports.map((p, i) => ({
        ...p,
        x: type === 'input' ? nx : nx + nw,
        y: startY + i * spacing + spacing / 2,
        type
      }));
    }

    // ================================================================
    // RENDER DETAIL
    // ================================================================
    function renderDetail(ctxName) {
      const vp = document.getElementById('viewport');
      vp.innerHTML = '';
      currentView = 'detail'; currentContext = ctxName;
      document.getElementById('btn-back').style.display = 'inline-block';
      document.getElementById('view-label').textContent = (ctxName.split('.').slice(-1)[0] || ctxName);

      const nodes = layoutDetail(ctxName);
      const memberIds = new Set(ctxMap.get(ctxName).members);

      // Background regions
      drawRegionBg(vp, nodes, id => memberIds.has(id), ctxName, 0.35, false);
      drawRegionBg(vp, nodes, id => !memberIds.has(id), 'External', 0.15, true);

      // Wires — port-level routing
      const wireGroup = se('g', { id: 'wires' });
      DATA.edges.forEach(edge => {
        const fn = nodes.get(edge.from), tn = nodes.get(edge.to);
        if (!fn || !tn) return;

        // Match output port by function name
        const outP = (fn.outputPorts || []).find(p => p.name === edge.from_port);
        // Match input port: the dependency name matches the source module's short name
        const inP = (tn.inputPorts || []).find(p => p.name === fn.short || p.module === edge.from);

        const x1 = outP ? outP.x : fn.x + fn.w;
        const y1 = outP ? outP.y : fn.y + fn.h / 2;
        const x2 = inP ? inP.x : tn.x;
        const y2 = inP ? inP.y : tn.y + tn.h / 2;

        wireGroup.appendChild(makeWire(x1, y1, x2, y2, edge.bypasses_boundary, edge.from, edge.to, edge.crosses_boundary));
      });
      vp.appendChild(wireGroup);
      vp.appendChild(se('g', { id: 'wire-highlights' }));

      // Module nodes
      nodes.forEach((n, id) => {
        const g = se('g', { class: `node-frame layer-${n.layer}`, 'data-id': id });
        const rect = sr(n.x, n.y, n.w, n.h, 'node-bg');
        if (n.external) rect.setAttribute('opacity', '0.5');
        g.appendChild(rect);

        const titleText = n.short.length > 22 ? n.short.slice(0, 20) + '..' : n.short;
        g.appendChild(st(n.x + 10, n.y + 16, titleText, n.is_boundary ? 'node-title boundary' : 'node-title internal'));

        (n.inputPorts || []).forEach(p => {
          g.appendChild(sc(p.x, p.y, PORT_R, 'port-dot in'));
          g.appendChild(st(p.x + 8, p.y + 3, p.name, 'port-label'));
        });
        (n.outputPorts || []).forEach(p => {
          const connected = p.callers > 0;
          g.appendChild(sc(p.x, p.y, PORT_R, 'port-dot ' + (connected ? 'out' : 'unconnected')));
          const lbl = st(p.x - 8, p.y + 3, p.name, 'port-label');
          lbl.setAttribute('text-anchor', 'end');
          g.appendChild(lbl);
        });

        g.addEventListener('click', e => {
          e.stopPropagation();
          selectNode(id, nodes);
          setInfo(buildModuleInfo(n));
        });
        vp.appendChild(g);
      });

      setInfo(buildContextInfo(ctxName));
      zoomToFit();
    }

    function drawRegionBg(vp, nodes, filterFn, label, opacity, dashed) {
      const filtered = [];
      nodes.forEach((n, id) => { if (filterFn(id)) filtered.push(n); });
      if (filtered.length === 0) return;
      const pad = 20;
      const x0 = Math.min(...filtered.map(n => n.x)) - pad;
      const y0 = Math.min(...filtered.map(n => n.y)) - 30;
      const x1 = Math.max(...filtered.map(n => n.x + n.w)) + pad;
      const y1 = Math.max(...filtered.map(n => n.y + n.h)) + pad;
      const bg = sr(x0, y0, x1 - x0, y1 - y0, 'ctx-bg normal');
      bg.setAttribute('opacity', String(opacity));
      if (dashed) bg.setAttribute('stroke-dasharray', '6 3');
      vp.appendChild(bg);
      vp.appendChild(st(x0 + 10, y0 + 16, label, 'ctx-subtitle'));
    }

    // ================================================================
    // WIRE FACTORY — Bezier from (x1,y1) output port to (x2,y2) input port
    // ================================================================
    function makeWire(x1, y1, x2, y2, isBypass, fromId, toId, crossBoundary) {
      // If target is to the left, route around with wider control points
      const goesLeft = x2 < x1;
      let path;
      if (goesLeft) {
        // Route: go right, swing down/up, come back left
        const detour = 60;
        const midY = (y1 + y2) / 2 + (y2 > y1 ? detour : -detour);
        path = `M ${x1} ${y1} C ${x1 + detour} ${y1}, ${x1 + detour} ${midY}, ${(x1+x2)/2} ${midY} S ${x2 - detour} ${y2}, ${x2} ${y2}`;
      } else {
        const dx = Math.max(Math.abs(x2 - x1) * 0.4, 40);
        path = `M ${x1} ${y1} C ${x1+dx} ${y1}, ${x2-dx} ${y2}, ${x2} ${y2}`;
      }

      let cls = 'wire normal';
      let marker = 'url(#arrow)';
      if (isBypass) { cls = 'wire bypass'; marker = 'url(#arrow-red)'; }
      else if (crossBoundary) { cls = 'wire cross-boundary'; }

      const wire = se('path', { d: path, class: cls, 'marker-end': marker });
      wire.setAttribute('data-from', fromId);
      wire.setAttribute('data-to', toId);
      return wire;
    }

    // ================================================================
    // NAVIGATION
    // ================================================================
    function enterContext(ctxName) {
      clearSelection();
      renderDetail(ctxName);
    }
    function showOverview() {
      clearSelection();
      renderOverview();
    }

    // ================================================================
    // PAN & ZOOM
    // ================================================================
    const svg = document.getElementById('diagram');

    function updateTransform() {
      document.getElementById('viewport').setAttribute('transform', `translate(${viewX},${viewY}) scale(${zoom})`);
    }

    svg.addEventListener('wheel', e => {
      e.preventDefault();
      const factor = e.deltaY > 0 ? 0.9 : 1.1;
      const newZoom = Math.max(0.05, Math.min(6, zoom * factor));
      const rect = svg.getBoundingClientRect();
      const mx = e.clientX - rect.left, my = e.clientY - rect.top;
      viewX = mx - (mx - viewX) * (newZoom / zoom);
      viewY = my - (my - viewY) * (newZoom / zoom);
      zoom = newZoom;
      updateTransform();
    });

    svg.addEventListener('mousedown', e => {
      if (e.target.closest('.ctx-frame') || e.target.closest('.node-frame')) return;
      dragging = true; lastX = e.clientX; lastY = e.clientY;
      svg.style.cursor = 'grabbing';
    });
    svg.addEventListener('mousemove', e => {
      if (!dragging) return;
      viewX += e.clientX - lastX; viewY += e.clientY - lastY;
      lastX = e.clientX; lastY = e.clientY;
      updateTransform();
    });
    svg.addEventListener('mouseup', () => { dragging = false; svg.style.cursor = 'default'; });

    svg.addEventListener('click', e => {
      if (!e.target.closest('.ctx-frame') && !e.target.closest('.node-frame')) {
        clearSelection();
        if (currentView === 'overview') setInfo(null);
      }
    });

    // ================================================================
    // SELECTION & WIRE HIGHLIGHTING
    // ================================================================
    function selectNode(nodeId, nodeLayouts) {
      clearSelection();
      document.getElementById('viewport').classList.add('dimmed');

      const el = document.querySelector(`[data-id="${nodeId}"]`);
      if (el) { el.classList.add('selected', 'highlighted'); }

      const connectedIds = new Set([nodeId]);
      const hlGroup = document.getElementById('wire-highlights');

      document.querySelectorAll('.wire').forEach(wire => {
        const from = wire.getAttribute('data-from'), to = wire.getAttribute('data-to');
        if (from === nodeId || to === nodeId) {
          const hl = wire.cloneNode();
          hl.removeAttribute('class');
          hl.classList.add('wire-highlight');
          hl.classList.add(wire.classList.contains('bypass') ? 'violation' : (from === nodeId ? 'outgoing' : 'incoming'));
          hl.removeAttribute('marker-end');
          hlGroup.appendChild(hl);
          connectedIds.add(from); connectedIds.add(to);
        }
      });

      connectedIds.forEach(id => {
        const el = document.querySelector(`[data-id="${id}"]`);
        if (el) el.classList.add('highlighted');
      });
    }

    function clearSelection() {
      document.getElementById('viewport').classList.remove('dimmed');
      document.querySelectorAll('.selected, .highlighted').forEach(el => el.classList.remove('selected', 'highlighted'));
      const hlGroup = document.getElementById('wire-highlights');
      if (hlGroup) hlGroup.innerHTML = '';
    }

    // ================================================================
    // ZOOM TO FIT (accounts for sidebar)
    // ================================================================
    function zoomToFit() {
      const screenW = window.innerWidth - PANEL_W;
      const screenH = window.innerHeight;

      const rects = document.querySelectorAll('#viewport rect');
      let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
      rects.forEach(r => {
        const x = +r.getAttribute('x'), y = +r.getAttribute('y');
        const w = +r.getAttribute('width'), h = +r.getAttribute('height');
        if (w > 0 && h > 0) {
          minX = Math.min(minX, x); minY = Math.min(minY, y);
          maxX = Math.max(maxX, x + w); maxY = Math.max(maxY, y + h);
        }
      });
      if (!isFinite(minX)) return;

      const contentW = maxX - minX + 80, contentH = maxY - minY + 80;
      zoom = Math.min(screenW / contentW, screenH / contentH) * 0.88;
      viewX = (screenW - contentW * zoom) / 2 - minX * zoom;
      viewY = (screenH - contentH * zoom) / 2 - minY * zoom;
      updateTransform();
    }

    // ================================================================
    // INFO SIDEBAR
    // ================================================================
    function setInfo(html) {
      const content = document.getElementById('info-content');
      content.innerHTML = html || '<div id="info-hint">Click a context or module to see details</div>';
    }

    function buildContextInfo(ctxName) {
      const ctx = ctxMap.get(ctxName);
      if (!ctx) return '';
      const shortCtx = ctxName.split('.').slice(-1)[0];

      let h = `<h2>${shortCtx}</h2>`;
      h += `<div style="color:#90a4ae;margin-bottom:8px;font-size:11px">${ctxName}</div>`;
      h += `<h3>Metrics</h3>`;
      h += statRow('Modules', ctx.members.length);
      h += statRow('Cohesion', (ctx.cohesion * 100).toFixed(0) + '%');
      h += statRow('Coupling', (ctx.coupling * 100).toFixed(0) + '%');
      h += statRow('Internal calls', ctx.internal_calls);
      h += statRow('Incoming calls', ctx.incoming_calls);
      h += statRow('Outgoing calls', ctx.outgoing_calls);
      if (ctx.leak_calls > 0) h += statRow('Boundary leaks', ctx.leak_calls, true);

      h += `<h3>Members</h3><ul class="member-list">`;
      ctx.members.forEach(m => {
        const short = m.split('.').slice(-1)[0];
        const isBoundary = m === ctx.boundary_module;
        h += `<li>${short}${isBoundary ? '<span class="boundary-tag">boundary</span>' : ''}</li>`;
      });
      h += '</ul>';
      return h;
    }

    function buildModuleInfo(node) {
      let h = `<h2>${node.short} <span class="badge ${node.layer}">${node.layer}</span></h2>`;
      h += `<div style="color:#90a4ae;margin-bottom:6px;font-size:11px">${node.id}</div>`;
      if (node.is_boundary) h += `<div style="color:#1565C0;font-size:10px;font-weight:600;margin-bottom:8px">BOUNDARY MODULE</div>`;

      if (node.behaviours?.length) h += `<h3>Behaviours</h3><div style="font-size:11px">${node.behaviours.join(', ')}</div>`;
      if (node.struct_fields?.length) h += `<h3>Struct</h3><div style="font-size:11px;word-break:break-all">${node.struct_fields.join(', ')}</div>`;

      h += `<h3>Dependencies (inputs)</h3><ul class="port-list">`;
      if (!node.inputs?.length) h += '<li style="color:#ccc">none</li>';
      (node.inputs || []).forEach(p => {
        const cross = p.context && p.context !== node.context;
        h += `<li style="${cross ? 'color:#E53935' : ''}">&#9679; ${p.name}${cross ? ' <span style="font-size:9px">(cross-ctx)</span>' : ''}</li>`;
      });
      h += '</ul>';

      h += `<h3>Exports (outputs)</h3><ul class="port-list">`;
      if (!node.outputs?.length) h += '<li style="color:#ccc">none</li>';
      (node.outputs || []).forEach(p => {
        h += `<li>&#9679; ${p.name} <span style="color:#90a4ae">(${p.callers} callers)</span></li>`;
      });
      h += '</ul>';
      return h;
    }

    function statRow(label, value, warn) {
      return `<div class="stat-row"><span class="stat-label">${label}</span><span class="stat-value${warn ? ' warn' : ''}">${value}</span></div>`;
    }

    // ================================================================
    // KEYBOARD
    // ================================================================
    document.addEventListener('keydown', e => {
      if (e.key === 'Escape') {
        if (currentView === 'detail') showOverview();
        else { clearSelection(); setInfo(null); }
      }
      if (e.key === 'f' || e.key === 'F') zoomToFit();
    });

    // ================================================================
    // INIT
    // ================================================================
    renderOverview();
    """
  end
end
