defmodule Archdo.Compiled.Diagram do
  @moduledoc false

  # Generates Mermaid diagrams from the compiled interaction graph.
  # Pure functions — takes a Graph struct, returns a Mermaid string.

  alias Archdo.{AST, Graph}
  alias Archdo.Compiled.Graph, as: CompiledGraph
  alias Archdo.Compiled.Query

  @doc """
  Generate an architecture overview diagram showing contexts as subgraphs,
  boundary modules highlighted, and cross-context dependencies as arrows.
  """
  @spec architecture_overview(CompiledGraph.t()) :: String.t()
  def architecture_overview(graph) do
    contexts = Query.discover_contexts(graph)

    # Build context membership lookup
    context_of = Query.build_context_membership(contexts)

    # Collect cross-context edges (aggregated at module level)
    cross_edges = collect_cross_context_edges(graph, context_of)

    lines = [
      "graph LR",
      ""
    ]

    # Render each context as a subgraph
    context_lines =
      contexts
      |> Enum.filter(fn ctx -> length(ctx.members) >= 2 end)
      |> Enum.flat_map(fn ctx ->
        render_context_subgraph(ctx)
      end)

    # Render cross-context edges
    edge_lines =
      Enum.map(cross_edges, fn {from_ctx, to_ctx, count} ->
        from_id = sanitize_id(from_ctx)
        to_id = sanitize_id(to_ctx)
        "  #{from_id} -->|#{count} calls| #{to_id}"
      end)

    # Style boundary modules
    style_lines =
      Enum.flat_map(contexts, fn ctx ->
        case ctx.boundary_module do
          nil ->
            []

          mod ->
            [
              "  style #{sanitize_id(AST.module_name(mod))} fill:#4CAF50,color:#fff,stroke:#2E7D32"
            ]
        end
      end)

    Enum.join(lines ++ context_lines ++ [""] ++ edge_lines ++ [""] ++ style_lines, "\n")
  end

  @doc """
  Generate a detailed diagram of a single context showing all modules,
  internal relationships, and external entry/exit points.
  """
  @spec context_detail(CompiledGraph.t(), String.t()) :: String.t()
  def context_detail(graph, context_name) do
    contexts = Query.discover_contexts(graph)

    case Enum.find(contexts, fn c -> c.context == context_name end) do
      nil ->
        "graph LR\n  no_context[Context '#{context_name}' not found]"

      ctx ->
        render_context_detail(graph, ctx)
    end
  end

  @doc """
  Generate a module-level dependency diagram showing all project modules
  and their call relationships. Edge thickness represents call count.
  """
  @spec module_dependencies(CompiledGraph.t()) :: String.t()
  def module_dependencies(graph) do
    modules = CompiledGraph.modules(graph)
    calls_by_module = CompiledGraph.calls_by_module(graph)
    project_modules = MapSet.new(Map.keys(modules))

    # Aggregate calls at module level
    edges =
      Enum.flat_map(calls_by_module, fn {caller_mod, calls} ->
        calls
        |> Enum.map(fn call -> elem(call.callee, 0) end)
        |> Enum.filter(&MapSet.member?(project_modules, &1))
        |> Enum.reject(&(&1 == caller_mod))
        |> Enum.frequencies()
        |> Enum.map(fn {callee_mod, count} -> {caller_mod, callee_mod, count} end)
      end)

    lines = ["graph LR", ""]

    # Render nodes
    node_lines =
      modules
      |> Map.keys()
      |> Enum.map(fn mod ->
        name = AST.short_name(mod)
        id = sanitize_id(AST.module_name(mod))
        "  #{id}[\"#{name}\"]"
      end)

    # Render edges (only show edges with >= 2 calls to reduce noise)
    edge_lines =
      edges
      |> Enum.filter(fn {_from, _to, count} -> count >= 2 end)
      |> Enum.map(fn {from, to, count} ->
        from_id = sanitize_id(AST.module_name(from))
        to_id = sanitize_id(AST.module_name(to))

        case count do
          n when n >= 10 -> "  #{from_id} ==>|#{count}| #{to_id}"
          _ -> "  #{from_id} -->|#{count}| #{to_id}"
        end
      end)

    Enum.join(lines ++ node_lines ++ [""] ++ edge_lines, "\n")
  end

  @doc """
  Generate a diagram showing only the public API of each context —
  which functions are called from outside, grouped by context.
  """
  @spec api_surface(CompiledGraph.t()) :: String.t()
  def api_surface(graph) do
    contexts = Query.discover_contexts(graph)

    lines = ["graph LR", ""]

    context_lines =
      contexts
      |> Enum.filter(fn ctx -> length(ctx.members) >= 2 and ctx.incoming_calls > 0 end)
      |> Enum.flat_map(fn ctx ->
        render_api_surface(graph, ctx)
      end)

    Enum.join(lines ++ context_lines, "\n")
  end

  @doc """
  Generate a blast radius diagram for a specific module showing
  transitive dependents layered by depth.
  """
  @spec blast_radius(CompiledGraph.t(), module()) :: String.t()
  def blast_radius(graph, module) do
    report = Query.blast_radius(graph, module)
    mod_name = AST.module_name(module)

    lines = [
      "graph TD",
      "",
      "  #{sanitize_id(mod_name)}[\"#{AST.short_name(module)} · CHANGED\"]",
      "  style #{sanitize_id(mod_name)} fill:#F44336,color:#fff,stroke:#B71C1C",
      ""
    ]

    depth_lines =
      report.transitive_dependents
      |> Enum.sort_by(fn {depth, _mods} -> depth end)
      |> Enum.flat_map(fn {depth, mods} ->
        subgraph_id = "depth_#{depth}"
        header = ["  subgraph #{subgraph_id}[\"Depth #{depth} — #{length(mods)} modules\"]"]

        mod_lines =
          mods
          |> Enum.take(15)
          |> Enum.map(fn mod ->
            id = sanitize_id(AST.module_name(mod))
            "    #{id}[\"#{AST.short_name(mod)}\"]"
          end)

        more =
          case length(mods) > 15 do
            true -> ["    more_#{depth}[\"... +#{length(mods) - 15} more\"]"]
            false -> []
          end

        footer = ["  end"]

        header ++ mod_lines ++ more ++ footer ++ [""]
      end)

    # Connect changed module to depth 1
    connect_lines =
      case Map.get(report.transitive_dependents, 1, []) do
        [] ->
          []

        depth1_mods ->
          depth1_mods
          |> Enum.take(15)
          |> Enum.map(fn mod ->
            "  #{sanitize_id(mod_name)} --> #{sanitize_id(AST.module_name(mod))}"
          end)
      end

    # Color depth layers
    color_lines =
      report.transitive_dependents
      |> Enum.sort_by(fn {depth, _} -> depth end)
      |> Enum.flat_map(fn {depth, mods} ->
        color =
          case depth do
            1 -> "#FF9800"
            2 -> "#FFC107"
            _ -> "#FFEB3B"
          end

        mods
        |> Enum.take(15)
        |> Enum.map(fn mod ->
          "  style #{sanitize_id(AST.module_name(mod))} fill:#{color}"
        end)
      end)

    Enum.join(lines ++ depth_lines ++ connect_lines ++ [""] ++ color_lines, "\n")
  end

  # --- Private helpers ---

  defp collect_cross_context_edges(graph, context_of) do
    calls_by_module = CompiledGraph.calls_by_module(graph)
    modules = CompiledGraph.modules(graph)
    project_modules = MapSet.new(Map.keys(modules))

    calls_by_module
    |> Enum.flat_map(fn {caller_mod, calls} ->
      caller_ctx = Map.get(context_of, caller_mod)

      calls
      |> Enum.map(fn call -> elem(call.callee, 0) end)
      |> Enum.filter(&MapSet.member?(project_modules, &1))
      |> Enum.map(fn callee_mod -> Map.get(context_of, callee_mod) end)
      |> Enum.reject(fn callee_ctx ->
        callee_ctx == nil or caller_ctx == nil or callee_ctx == caller_ctx
      end)
      |> Enum.map(fn callee_ctx -> {caller_ctx, callee_ctx} end)
    end)
    |> Enum.frequencies()
    |> Enum.map(fn {{from, to}, count} -> {from, to, count} end)
    |> Enum.sort_by(fn {_from, _to, count} -> count end, :desc)
  end

  defp render_context_subgraph(ctx) do
    ctx_id = sanitize_id(ctx.context)

    header = [
      "  subgraph #{ctx_id}[\"#{ctx.context} · cohesion: #{ctx.cohesion} | coupling: #{ctx.coupling}\"]"
    ]

    # Show boundary module prominently, then a sample of internal modules
    boundary_line =
      case ctx.boundary_module do
        nil ->
          []

        mod ->
          id = sanitize_id(AST.module_name(mod))
          ["    #{id}([\"#{AST.short_name(mod)} · BOUNDARY\"])"]
      end

    internal =
      ctx.members
      |> Enum.reject(fn mod -> mod == ctx.boundary_module end)
      |> Enum.take(8)
      |> Enum.map(fn mod ->
        id = sanitize_id(AST.module_name(mod))
        "    #{id}[\"#{AST.short_name(mod)}\"]"
      end)

    more =
      case length(ctx.members) > 9 do
        true -> ["    more_#{ctx_id}[\"... +#{length(ctx.members) - 9} more\"]"]
        false -> []
      end

    footer = ["  end", ""]

    header ++ boundary_line ++ internal ++ more ++ footer
  end

  defp render_context_detail(graph, ctx) do
    member_set = MapSet.new(ctx.members)

    lines = [
      "graph TD",
      "",
      "  subgraph #{sanitize_id(ctx.context)}[\"#{ctx.context}\"]"
    ]

    # Render all members
    member_lines =
      Enum.map(ctx.members, fn mod ->
        id = sanitize_id(AST.module_name(mod))
        name = AST.short_name(mod)

        case mod == ctx.boundary_module do
          true -> "    #{id}([\"#{name} · BOUNDARY\"])"
          false -> "    #{id}[\"#{name}\"]"
        end
      end)

    subgraph_end = ["  end", ""]

    # Internal call edges
    internal_edges =
      ctx.members
      |> Enum.flat_map(fn mod ->
        Query.module_dependencies(graph, mod)
        |> Enum.filter(&MapSet.member?(member_set, &1))
        |> Enum.map(fn dep -> {mod, dep} end)
      end)
      |> Enum.uniq()
      |> Enum.map(fn {from, to} ->
        "  #{sanitize_id(AST.module_name(from))} --> #{sanitize_id(AST.module_name(to))}"
      end)

    # External callers (show as dashed arrows)
    external_callers =
      ctx.leaking_modules
      |> Enum.take(5)
      |> Enum.flat_map(fn %{module: mod} ->
        callers = Query.module_dependents(graph, mod)

        callers
        |> Enum.reject(&MapSet.member?(member_set, &1))
        |> Enum.take(3)
        |> Enum.map(fn caller ->
          caller_id = sanitize_id(AST.module_name(caller))
          mod_id = sanitize_id(AST.module_name(mod))
          "  #{caller_id}[\"#{AST.short_name(caller)}\"] -.->|leak| #{mod_id}"
        end)
      end)

    # Style
    style_lines =
      case ctx.boundary_module do
        nil ->
          []

        mod ->
          [
            "",
            "  style #{sanitize_id(AST.module_name(mod))} fill:#4CAF50,color:#fff,stroke:#2E7D32"
          ]
      end

    leak_style =
      ctx.leaking_modules
      |> Enum.take(5)
      |> Enum.map(fn %{module: mod} ->
        "  style #{sanitize_id(AST.module_name(mod))} fill:#FF9800,color:#fff"
      end)

    Enum.join(
      lines ++
        member_lines ++
        subgraph_end ++ internal_edges ++ [""] ++ external_callers ++ style_lines ++ leak_style,
      "\n"
    )
  end

  defp render_api_surface(graph, ctx) do
    member_set = MapSet.new(ctx.members)
    ctx_id = sanitize_id(ctx.context)

    header = [
      "  subgraph #{ctx_id}[\"#{ctx.context} API\"]"
    ]

    # Find functions called from outside
    api_functions =
      Enum.flat_map(ctx.members, fn mod ->
        exports = Map.get(CompiledGraph.modules(graph), mod, %{exports: []}).exports

        exports
        |> Enum.filter(&called_from_outside?(&1, mod, graph, member_set))
        |> Enum.map(fn {func, arity} -> {mod, func, arity} end)
      end)

    fn_lines =
      api_functions
      |> Enum.take(20)
      |> Enum.map(fn {mod, func, arity} ->
        id = sanitize_id("#{AST.module_name(mod)}_#{func}_#{arity}")
        mod_short = AST.short_name(mod)
        "    #{id}[\"#{mod_short}.#{func}/#{arity}\"]"
      end)

    more =
      case length(api_functions) > 20 do
        true -> ["    more_api_#{ctx_id}[\"... +#{length(api_functions) - 20} more\"]"]
        false -> []
      end

    footer = ["  end", ""]

    header ++ fn_lines ++ more ++ footer
  end

  # --- AST vs Compiled Delta ---

  @type dep_edge :: {module(), module()}
  @type delta :: %{
          both: MapSet.t(dep_edge()),
          compiled_only: MapSet.t(dep_edge()),
          ast_only: MapSet.t(dep_edge()),
          compiled_total: non_neg_integer(),
          ast_total: non_neg_integer()
        }

  @doc """
  Compute the delta between AST-declared dependencies and compiled actual dependencies.

  `source_paths` is a list of directories containing .ex files (e.g., ["lib"]).
  The compiled graph is built from beam files.

  Returns a delta map classifying each module-level dependency edge as:
  - `both` — declared in AST AND confirmed in compiled (solid dependency)
  - `compiled_only` — NOT in AST but present in compiled (hidden: macro-injected, import-resolved)
  - `ast_only` — declared in AST but NOT in compiled (phantom: unused alias/import, dead code path)
  """
  @spec compute_delta(CompiledGraph.t(), [String.t()]) :: delta()
  def compute_delta(compiled_graph, source_paths) do
    # Build AST-level edges
    ast_edges = build_ast_edges(source_paths)

    # Build compiled-level edges
    compiled_edges = build_compiled_edges(compiled_graph)

    both = MapSet.intersection(ast_edges, compiled_edges)
    compiled_only = MapSet.difference(compiled_edges, ast_edges)
    ast_only = MapSet.difference(ast_edges, compiled_edges)

    %{
      both: both,
      compiled_only: compiled_only,
      ast_only: ast_only,
      compiled_total: MapSet.size(compiled_edges),
      ast_total: MapSet.size(ast_edges)
    }
  end

  @doc """
  Generate a Mermaid diagram showing the delta between AST and compiled dependencies.

  - Green solid arrows: confirmed in both AST and compiled
  - Red dashed arrows: compiled-only (hidden — macro-injected, import-resolved)
  - Grey dotted arrows: AST-only (phantom — unused alias/import, dead code path)
  """
  @spec dependency_delta(CompiledGraph.t(), [String.t()]) :: String.t()
  def dependency_delta(compiled_graph, source_paths) do
    delta = compute_delta(compiled_graph, source_paths)

    # Collect all modules involved
    all_modules =
      [delta.both, delta.compiled_only, delta.ast_only]
      |> Enum.flat_map(fn set ->
        set
        |> MapSet.to_list()
        |> Enum.flat_map(fn {from, to} -> [from, to] end)
      end)
      |> Enum.uniq()

    lines = [
      "graph LR",
      "",
      "  %% Legend",
      "  subgraph legend[\"Legend\"]",
      "    confirmed[\"Confirmed\"] ---|both AST + compiled| confirmed",
      "    hidden[\"Hidden\"] -.-|compiled only| hidden",
      "    phantom[\"Phantom\"] ~~~|AST only| phantom",
      "  end",
      "",
      "  %% #{MapSet.size(delta.both)} confirmed, #{MapSet.size(delta.compiled_only)} hidden, #{MapSet.size(delta.ast_only)} phantom",
      ""
    ]

    # Render nodes
    node_lines =
      Enum.map(all_modules, fn mod ->
        id = sanitize_id(AST.module_name(mod))
        "  #{id}[\"#{AST.short_name(mod)}\"]"
      end)

    # Render confirmed edges (green, solid)
    confirmed_lines =
      delta.both
      |> MapSet.to_list()
      |> Enum.take(50)
      |> Enum.map(fn {from, to} ->
        "  #{sanitize_id(AST.module_name(from))} -->|confirmed| #{sanitize_id(AST.module_name(to))}"
      end)

    # Render hidden edges (red, dashed) — the interesting ones
    hidden_lines =
      delta.compiled_only
      |> MapSet.to_list()
      |> Enum.take(30)
      |> Enum.map(fn {from, to} ->
        "  #{sanitize_id(AST.module_name(from))} -.->|hidden| #{sanitize_id(AST.module_name(to))}"
      end)

    # Render phantom edges (grey, dotted)
    phantom_lines =
      delta.ast_only
      |> MapSet.to_list()
      |> Enum.take(20)
      |> Enum.map(fn {from, to} ->
        "  #{sanitize_id(AST.module_name(from))} ~~~|phantom| #{sanitize_id(AST.module_name(to))}"
      end)

    # Style hidden endpoints
    hidden_style =
      delta.compiled_only
      |> MapSet.to_list()
      |> Enum.take(30)
      |> Enum.flat_map(fn {_from, to} -> [to] end)
      |> Enum.uniq()
      |> Enum.map(fn mod ->
        "  style #{sanitize_id(AST.module_name(mod))} stroke:#F44336,stroke-width:2px"
      end)

    phantom_style =
      delta.ast_only
      |> MapSet.to_list()
      |> Enum.take(20)
      |> Enum.flat_map(fn {from, _to} -> [from] end)
      |> Enum.uniq()
      |> Enum.map(fn mod ->
        "  style #{sanitize_id(AST.module_name(mod))} stroke:#9E9E9E,stroke-dasharray: 5 5"
      end)

    summary = [
      "",
      "  %% Summary: #{MapSet.size(delta.both)} confirmed | #{MapSet.size(delta.compiled_only)} hidden (macro/import) | #{MapSet.size(delta.ast_only)} phantom (unused)"
    ]

    Enum.join(
      lines ++
        node_lines ++
        [""] ++
        confirmed_lines ++
        [""] ++
        hidden_lines ++ [""] ++ phantom_lines ++ [""] ++ hidden_style ++ phantom_style ++ summary,
      "\n"
    )
  end

  @doc """
  Generate a focused delta diagram showing ONLY the differences — hidden and phantom
  edges, without the confirmed ones. This highlights what macros inject and what
  source code declares but doesn't use.
  """
  @spec dependency_delta_only(CompiledGraph.t(), [String.t()]) :: String.t()
  def dependency_delta_only(compiled_graph, source_paths) do
    delta = compute_delta(compiled_graph, source_paths)

    lines = [
      "graph LR",
      "",
      "  %% HIDDEN: #{MapSet.size(delta.compiled_only)} edges exist in compiled but NOT in source",
      "  %% PHANTOM: #{MapSet.size(delta.ast_only)} edges exist in source but NOT in compiled",
      ""
    ]

    # Hidden edges — these are the macro-injected, import-resolved dependencies
    hidden_section =
      case MapSet.size(delta.compiled_only) do
        0 ->
          ["  %% No hidden dependencies found"]

        _ ->
          hidden_header = ["  subgraph hidden_deps[\"Hidden Dependencies (compiled-only)\"]"]

          hidden_edges =
            delta.compiled_only
            |> MapSet.to_list()
            |> Enum.sort()
            |> Enum.take(40)
            |> Enum.map(fn {from, to} ->
              from_id = sanitize_id(AST.module_name(from))
              to_id = sanitize_id(AST.module_name(to))
              "    #{from_id} -.->|macro/import| #{to_id}"
            end)

          more =
            case MapSet.size(delta.compiled_only) > 40 do
              true -> ["    hidden_more[\"... +#{MapSet.size(delta.compiled_only) - 40} more\"]"]
              false -> []
            end

          hidden_header ++ hidden_edges ++ more ++ ["  end", ""]
      end

    # Phantom edges — these are declared but unused
    phantom_section =
      case MapSet.size(delta.ast_only) do
        0 ->
          ["  %% No phantom dependencies found"]

        _ ->
          phantom_header = ["  subgraph phantom_deps[\"Phantom Dependencies (AST-only)\"]"]

          phantom_edges =
            delta.ast_only
            |> MapSet.to_list()
            |> Enum.sort()
            |> Enum.take(30)
            |> Enum.map(fn {from, to} ->
              from_id = sanitize_id(AST.module_name(from))
              to_id = sanitize_id(AST.module_name(to))
              "    #{from_id} ~~~|unused| #{to_id}"
            end)

          more =
            case MapSet.size(delta.ast_only) > 30 do
              true -> ["    phantom_more[\"... +#{MapSet.size(delta.ast_only) - 30} more\"]"]
              false -> []
            end

          phantom_header ++ phantom_edges ++ more ++ ["  end"]
      end

    # Style
    style_lines = [
      "",
      "  style hidden_deps fill:#FFF3E0,stroke:#F44336",
      "  style phantom_deps fill:#F5F5F5,stroke:#9E9E9E"
    ]

    Enum.join(lines ++ hidden_section ++ phantom_section ++ style_lines, "\n")
  end

  # §§ elixir-implementing: §2.1 — extracted predicate replaces a
  # nested any-inside-filter-inside-flat_map.
  defp called_from_outside?({func, arity}, mod, graph, member_set) do
    graph
    |> Query.callers_of({mod, func, arity})
    |> Enum.any?(&caller_outside_member_set?(&1, member_set))
  end

  defp caller_outside_member_set?(call, member_set) do
    not MapSet.member?(member_set, elem(call.caller, 0))
  end

  # Build set of {source_atom, target_atom} edges from AST analysis
  defp build_ast_edges(source_paths) do
    files = Archdo.collect_files(source_paths)

    file_asts =
      for file <- files, {:ok, ast} <- [AST.parse_file(file)], do: {file, ast}

    ast_graph = Graph.build(file_asts)

    # The AST graph uses string module names. Convert to atoms for comparison
    # with the compiled graph. Only keep fully-qualified names (contain ".")
    # to avoid short alias names like "AST" which don't match compiled atoms.
    ast_graph.edges
    |> Enum.filter(fn edge ->
      String.contains?(edge.source, ".") and String.contains?(edge.target, ".")
    end)
    |> Enum.map(fn edge ->
      source = string_to_module(edge.source)
      target = string_to_module(edge.target)
      {source, target}
    end)
    |> Enum.reject(fn {source, target} -> source == nil or target == nil end)
    |> MapSet.new()
  end

  # Build set of {source_atom, target_atom} edges from compiled call graph
  defp build_compiled_edges(graph) do
    calls_by_module = CompiledGraph.calls_by_module(graph)
    modules = CompiledGraph.modules(graph)
    project_modules = MapSet.new(Map.keys(modules))

    calls_by_module
    |> Enum.flat_map(fn {caller_mod, calls} ->
      calls
      |> Enum.map(fn call -> elem(call.callee, 0) end)
      |> Enum.filter(&MapSet.member?(project_modules, &1))
      |> Enum.reject(&(&1 == caller_mod))
      |> Enum.uniq()
      |> Enum.map(fn callee_mod -> {caller_mod, callee_mod} end)
    end)
    |> MapSet.new()
  end

  defp string_to_module(str) when is_binary(str) do
    Module.concat([str])
  rescue
    _ -> nil
  end

  # --- Dataflow Diagram (LabVIEW/Grasshopper inspired) ---

  @doc """
  Generate a dataflow diagram for a specific module, showing it as a box with
  input terminals (arguments) on the left and output terminals (return type)
  on the right. Connected modules shown with typed wires.

  Inspired by LabVIEW block diagrams and Grasshopper component graphs.
  """
  @spec dataflow_module(CompiledGraph.t(), module()) :: String.t()
  def dataflow_module(graph, module) do
    mod_name = AST.module_name(module)
    mod_id = sanitize_id(mod_name)

    # Get function clause info for this module
    clauses_map =
      case graph.beam_dir do
        nil -> %{}
        dir -> CompiledGraph.extract_function_clauses(dir)
      end

    functions = Map.get(clauses_map, module, [])
    exports = Enum.filter(functions, & &1.exported)

    # What this module knows about (outgoing)
    outgoing = Query.knows_about(graph, module)

    # Who knows about this module (incoming)
    incoming = Query.known_by(graph, module)

    lines = [
      "graph LR",
      ""
    ]

    # Render incoming callers on the left
    caller_lines =
      incoming
      |> Enum.take(10)
      |> Enum.flat_map(fn entry ->
        caller_id = sanitize_id(AST.module_name(entry.module))
        caller_short = AST.short_name(entry.module)

        fns = Enum.map_join(entry.functions_called, ", ", fn {f, a} -> "#{f}/#{a}" end)

        [
          "  #{caller_id}[\"#{caller_short}\"] -->|\"#{fns}\"| #{mod_id}"
        ]
      end)

    # Render the module itself as a detailed box
    export_list =
      exports
      |> Enum.take(15)
      |> Enum.map_join(", ", fn fn_info ->
        clause_tag =
          case fn_info.has_catch_all do
            true -> ""
            false -> " ⚠"
          end

        return_tag = format_return_shape(fn_info)

        "#{fn_info.name}/#{fn_info.arity}#{clause_tag} → #{return_tag}"
      end)

    more_exports =
      case length(exports) > 15 do
        true -> ", ... +#{length(exports) - 15} more"
        false -> ""
      end

    module_lines = [
      "",
      "  #{mod_id}[\"#{mod_name} · #{export_list}#{more_exports}\"]",
      ""
    ]

    # Render outgoing dependencies on the right
    dep_lines =
      outgoing
      |> Enum.take(10)
      |> Enum.flat_map(fn entry ->
        dep_id = sanitize_id(AST.module_name(entry.module))
        dep_short = AST.short_name(entry.module)

        fns = Enum.map_join(entry.functions_called, ", ", fn {f, a} -> "#{f}/#{a}" end)

        wire_style = wire_style_for(entry)

        [
          "  #{mod_id} #{wire_style}|\"#{fns}\"| #{dep_id}[\"#{dep_short}\"]"
        ]
      end)

    # Style the central module
    style_lines = [
      "",
      "  style #{mod_id} fill:#E3F2FD,stroke:#1565C0,stroke-width:2px,text-align:left"
    ]

    Enum.join(lines ++ caller_lines ++ module_lines ++ dep_lines ++ style_lines, "\n")
  end

  @doc """
  Generate a dataflow diagram for an entire context, showing each module
  as a component with terminals, internal wiring, and external connections.
  Uses LabVIEW-style layout: inputs left, processing center, outputs right.
  """
  @spec dataflow_context(CompiledGraph.t(), String.t()) :: String.t()
  def dataflow_context(graph, context_name) do
    contexts = Query.discover_contexts(graph)

    case Enum.find(contexts, fn c -> c.context == context_name end) do
      nil ->
        "graph LR\n  not_found[\"Context '#{context_name}' not found\"]"

      ctx ->
        render_dataflow_context(graph, ctx)
    end
  end

  defp render_dataflow_context(graph, ctx) do
    member_set = MapSet.new(ctx.members)
    ctx_id = sanitize_id(ctx.context)

    # Classify members by role
    boundary = ctx.boundary_module
    internal = Enum.reject(ctx.members, &(&1 == boundary))

    # Find external callers (incoming to context)
    external_callers =
      ctx.members
      |> Enum.flat_map(fn mod ->
        Query.known_by(graph, mod)
        |> Enum.reject(fn e -> MapSet.member?(member_set, e.module) end)
        |> Enum.map(fn e -> {e.module, mod, e.functions_called, e.call_count} end)
      end)
      |> Enum.group_by(fn {caller, _callee, _fns, _count} -> caller end)
      |> Enum.take(8)

    # Find external dependencies (outgoing from context)
    external_deps =
      ctx.members
      |> Enum.flat_map(fn mod ->
        Query.knows_about(graph, mod)
        |> Enum.reject(fn e -> MapSet.member?(member_set, e.module) end)
        |> Enum.map(fn e -> {mod, e.module, e.functions_called, e.call_count} end)
      end)
      |> Enum.group_by(fn {_caller, dep, _fns, _count} -> dep end)
      |> Enum.sort_by(fn {_dep, calls} -> -length(calls) end)
      |> Enum.take(8)

    lines = ["graph LR", ""]

    # Left side: external callers
    caller_lines =
      Enum.flat_map(external_callers, &external_caller_lines/1)

    # Center: context subgraph
    context_lines = ["", "  subgraph #{ctx_id}[\"#{ctx.context}\"]"]

    boundary_line =
      case boundary do
        nil ->
          []

        mod ->
          id = sanitize_id(AST.module_name(mod))
          ["    #{id}{{\"#{AST.short_name(mod)} · BOUNDARY\"}}"]
      end

    internal_lines =
      internal
      |> Enum.take(12)
      |> Enum.map(fn mod ->
        id = sanitize_id(AST.module_name(mod))
        "    #{id}[\"#{AST.short_name(mod)}\"]"
      end)

    more_line =
      case length(internal) > 12 do
        true -> ["    more_#{ctx_id}[\"... +#{length(internal) - 12} more\"]"]
        false -> []
      end

    context_end = ["  end", ""]

    # Internal wiring within context
    internal_wiring =
      ctx.members
      |> Enum.flat_map(fn mod ->
        Query.knows_about(graph, mod)
        |> Enum.filter(fn e -> MapSet.member?(member_set, e.module) end)
        |> Enum.map(fn e ->
          from_id = sanitize_id(AST.module_name(mod))
          to_id = sanitize_id(AST.module_name(e.module))
          "  #{from_id} --> #{to_id}"
        end)
      end)
      |> Enum.uniq()

    # Right side: external dependencies
    dep_lines = Enum.flat_map(external_deps, &external_dep_lines/1)

    # Styling
    style_lines = [""]

    boundary_style =
      case boundary do
        nil ->
          []

        mod ->
          ["  style #{sanitize_id(AST.module_name(mod))} fill:#4CAF50,color:#fff,stroke:#2E7D32"]
      end

    # Style external callers as input terminals (blue)
    caller_style =
      Enum.map(external_callers, fn {caller, _} ->
        "  style #{sanitize_id(AST.module_name(caller))} fill:#BBDEFB,stroke:#1565C0"
      end)

    # Style external deps as output terminals (orange)
    dep_style =
      Enum.map(external_deps, fn {dep, _} ->
        "  style #{sanitize_id(AST.module_name(dep))} fill:#FFE0B2,stroke:#E65100"
      end)

    Enum.join(
      lines ++
        caller_lines ++
        context_lines ++
        boundary_line ++
        internal_lines ++
        more_line ++
        context_end ++
        internal_wiring ++
        [""] ++
        dep_lines ++
        style_lines ++
        boundary_style ++
        caller_style ++ dep_style,
      "\n"
    )
  end

  defp format_return_shape(fn_info) do
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

      [:binary] ->
        "<<>>"

      [:call] ->
        "fn()"

      [:variable] ->
        "var"

      [{:mixed, _}] ->
        "mixed"

      _ ->
        tags = for {:tagged_tuple, t} <- shapes, do: t
        format_tag_list(tags)
    end
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # the empty-list shape.
  defp format_tag_list([]), do: "?"
  defp format_tag_list(tags), do: Enum.map_join(tags, "|", fn t -> ":#{t}" end)

  defp wire_style_for(entry) do
    case entry.call_count do
      n when n >= 10 -> "==>"
      _ -> "-->"
    end
  end

  # §§ elixir-implementing: §2.1 — extracted helper flattens the
  # depth-3 Enum.flat_map(fn -> Enum.map(fn ...) end). Mirrors the
  # external_dep_lines shape but for the inverse direction (callers
  # rather than dependencies).
  defp external_caller_lines({caller, calls}) do
    caller_id = sanitize_id(AST.module_name(caller))
    caller_short = AST.short_name(caller)
    targets = Enum.map(calls, &callee_id_and_fns/1)

    edge_lines = Enum.map(targets, fn {callee_id, fn_str} ->
      "  #{caller_id} -->|\"#{fn_str}\"| #{callee_id}"
    end)

    ["  #{caller_id}([\"#{caller_short}\"])" | edge_lines]
  end

  defp callee_id_and_fns({_, callee, fns, _}) do
    callee_id = sanitize_id(AST.module_name(callee))
    fn_str = Enum.map_join(fns, ", ", fn {f, a} -> "#{f}/#{a}" end)
    {callee_id, fn_str}
  end

  defp external_dep_lines({dep, calls}) do
    dep_id = sanitize_id(AST.module_name(dep))
    dep_short = AST.short_name(dep)

    sources =
      calls
      |> Enum.map(&caller_id_and_fns/1)
      |> Enum.take(3)

    edge_lines = Enum.map(sources, fn {caller_id, fn_str} ->
      "  #{caller_id} -.->|\"#{fn_str}\"| #{dep_id}"
    end)

    ["  #{dep_id}([\"#{dep_short}\"])" | edge_lines]
  end

  defp caller_id_and_fns({caller, _, fns, _}) do
    caller_id = sanitize_id(AST.module_name(caller))
    fn_str = Enum.map_join(fns, ", ", fn {f, a} -> "#{f}/#{a}" end)
    {caller_id, fn_str}
  end

  defp sanitize_id(str) do
    str
    |> String.replace(".", "_")
    |> String.replace("-", "_")
    |> String.replace(" ", "_")
    |> String.replace("/", "_")
  end
end
