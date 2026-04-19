defmodule Archdo.Compiled.Diagram do
  @moduledoc false

  # Generates Mermaid diagrams from the compiled interaction graph.
  # Pure functions — takes a Graph struct, returns a Mermaid string.

  alias Archdo.{AST, Graph}
  alias Archdo.Compiled.Graph, as: CompiledGraph

  @doc """
  Generate an architecture overview diagram showing contexts as subgraphs,
  boundary modules highlighted, and cross-context dependencies as arrows.
  """
  @spec architecture_overview(CompiledCompiledGraph.t()) :: String.t()
  def architecture_overview(%CompiledGraph{} = graph) do
    contexts = CompiledGraph.discover_contexts(graph)

    # Build context membership lookup
    context_of = build_context_lookup(contexts)

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
      cross_edges
      |> Enum.map(fn {from_ctx, to_ctx, count} ->
        from_id = sanitize_id(from_ctx)
        to_id = sanitize_id(to_ctx)
        "  #{from_id} -->|#{count} calls| #{to_id}"
      end)

    # Style boundary modules
    style_lines =
      contexts
      |> Enum.flat_map(fn ctx ->
        case ctx.boundary_module do
          nil -> []
          mod -> ["  style #{sanitize_id(format_mod(mod))} fill:#4CAF50,color:#fff,stroke:#2E7D32"]
        end
      end)

    Enum.join(lines ++ context_lines ++ [""] ++ edge_lines ++ [""] ++ style_lines, "\n")
  end

  @doc """
  Generate a detailed diagram of a single context showing all modules,
  internal relationships, and external entry/exit points.
  """
  @spec context_detail(CompiledGraph.t(), String.t()) :: String.t()
  def context_detail(%CompiledGraph{} = graph, context_name) do
    contexts = CompiledGraph.discover_contexts(graph)

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
  def module_dependencies(%CompiledGraph{modules: modules, calls_by_module: calls_by_module} = _graph) do
    project_modules = MapSet.new(Map.keys(modules))

    # Aggregate calls at module level
    edges =
      calls_by_module
      |> Enum.flat_map(fn {caller_mod, calls} ->
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
        name = short_name(mod)
        id = sanitize_id(format_mod(mod))
        "  #{id}[\"#{name}\"]"
      end)

    # Render edges (only show edges with >= 2 calls to reduce noise)
    edge_lines =
      edges
      |> Enum.filter(fn {_from, _to, count} -> count >= 2 end)
      |> Enum.map(fn {from, to, count} ->
        from_id = sanitize_id(format_mod(from))
        to_id = sanitize_id(format_mod(to))

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
  def api_surface(%CompiledGraph{} = graph) do
    contexts = CompiledGraph.discover_contexts(graph)

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
  def blast_radius(%CompiledGraph{} = graph, module) do
    report = CompiledGraph.blast_radius(graph, module)
    mod_name = format_mod(module)

    lines = [
      "graph TD",
      "",
      "  #{sanitize_id(mod_name)}[\"#{short_name(module)}<br/>CHANGED\"]",
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
            id = sanitize_id(format_mod(mod))
            "    #{id}[\"#{short_name(mod)}\"]"
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
            "  #{sanitize_id(mod_name)} --> #{sanitize_id(format_mod(mod))}"
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
          "  style #{sanitize_id(format_mod(mod))} fill:#{color}"
        end)
      end)

    Enum.join(lines ++ depth_lines ++ connect_lines ++ [""] ++ color_lines, "\n")
  end

  # --- Private helpers ---

  defp build_context_lookup(contexts) do
    contexts
    |> Enum.flat_map(fn ctx ->
      Enum.map(ctx.members, fn mod -> {mod, ctx.context} end)
    end)
    |> Map.new()
  end

  defp collect_cross_context_edges(%CompiledGraph{calls_by_module: calls_by_module, modules: modules}, context_of) do
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
      "  subgraph #{ctx_id}[\"#{ctx.context}<br/>cohesion: #{ctx.cohesion} | coupling: #{ctx.coupling}\"]"
    ]

    # Show boundary module prominently, then a sample of internal modules
    boundary_line =
      case ctx.boundary_module do
        nil -> []
        mod ->
          id = sanitize_id(format_mod(mod))
          ["    #{id}([\"#{short_name(mod)}<br/>BOUNDARY\"])"]
      end

    internal =
      ctx.members
      |> Enum.reject(fn mod -> mod == ctx.boundary_module end)
      |> Enum.take(8)
      |> Enum.map(fn mod ->
        id = sanitize_id(format_mod(mod))
        "    #{id}[\"#{short_name(mod)}\"]"
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
      ctx.members
      |> Enum.map(fn mod ->
        id = sanitize_id(format_mod(mod))
        name = short_name(mod)

        case mod == ctx.boundary_module do
          true -> "    #{id}([\"#{name}<br/>BOUNDARY\"])"
          false -> "    #{id}[\"#{name}\"]"
        end
      end)

    subgraph_end = ["  end", ""]

    # Internal call edges
    internal_edges =
      ctx.members
      |> Enum.flat_map(fn mod ->
        CompiledGraph.module_dependencies(graph, mod)
        |> Enum.filter(&MapSet.member?(member_set, &1))
        |> Enum.map(fn dep -> {mod, dep} end)
      end)
      |> Enum.uniq()
      |> Enum.map(fn {from, to} ->
        "  #{sanitize_id(format_mod(from))} --> #{sanitize_id(format_mod(to))}"
      end)

    # External callers (show as dashed arrows)
    external_callers =
      ctx.leaking_modules
      |> Enum.take(5)
      |> Enum.flat_map(fn %{module: mod} ->
        callers = CompiledGraph.module_dependents(graph, mod)

        callers
        |> Enum.reject(&MapSet.member?(member_set, &1))
        |> Enum.take(3)
        |> Enum.map(fn caller ->
          caller_id = sanitize_id(format_mod(caller))
          mod_id = sanitize_id(format_mod(mod))
          "  #{caller_id}[\"#{short_name(caller)}\"] -.->|leak| #{mod_id}"
        end)
      end)

    # Style
    style_lines =
      case ctx.boundary_module do
        nil -> []
        mod -> ["", "  style #{sanitize_id(format_mod(mod))} fill:#4CAF50,color:#fff,stroke:#2E7D32"]
      end

    leak_style =
      ctx.leaking_modules
      |> Enum.take(5)
      |> Enum.map(fn %{module: mod} ->
        "  style #{sanitize_id(format_mod(mod))} fill:#FF9800,color:#fff"
      end)

    Enum.join(
      lines ++ member_lines ++ subgraph_end ++ internal_edges ++ [""] ++ external_callers ++ style_lines ++ leak_style,
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
      ctx.members
      |> Enum.flat_map(fn mod ->
        exports = Map.get(graph.modules, mod, %{exports: []}).exports

        exports
        |> Enum.filter(fn {func, arity} ->
          mfa = {mod, func, arity}
          callers = CompiledGraph.callers_of(graph, mfa)

          Enum.any?(callers, fn call ->
            caller_mod = elem(call.caller, 0)
            not MapSet.member?(member_set, caller_mod)
          end)
        end)
        |> Enum.map(fn {func, arity} -> {mod, func, arity} end)
      end)

    fn_lines =
      api_functions
      |> Enum.take(20)
      |> Enum.map(fn {mod, func, arity} ->
        id = sanitize_id("#{format_mod(mod)}_#{func}_#{arity}")
        mod_short = short_name(mod)
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
  def compute_delta(%CompiledGraph{} = compiled_graph, source_paths) do
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
  def dependency_delta(%CompiledGraph{} = compiled_graph, source_paths) do
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
      all_modules
      |> Enum.map(fn mod ->
        id = sanitize_id(format_mod(mod))
        "  #{id}[\"#{short_name(mod)}\"]"
      end)

    # Render confirmed edges (green, solid)
    confirmed_lines =
      delta.both
      |> MapSet.to_list()
      |> Enum.take(50)
      |> Enum.map(fn {from, to} ->
        "  #{sanitize_id(format_mod(from))} -->|confirmed| #{sanitize_id(format_mod(to))}"
      end)

    # Render hidden edges (red, dashed) — the interesting ones
    hidden_lines =
      delta.compiled_only
      |> MapSet.to_list()
      |> Enum.take(30)
      |> Enum.map(fn {from, to} ->
        "  #{sanitize_id(format_mod(from))} -.->|hidden| #{sanitize_id(format_mod(to))}"
      end)

    # Render phantom edges (grey, dotted)
    phantom_lines =
      delta.ast_only
      |> MapSet.to_list()
      |> Enum.take(20)
      |> Enum.map(fn {from, to} ->
        "  #{sanitize_id(format_mod(from))} ~~~|phantom| #{sanitize_id(format_mod(to))}"
      end)

    # Style hidden endpoints
    hidden_style =
      delta.compiled_only
      |> MapSet.to_list()
      |> Enum.take(30)
      |> Enum.flat_map(fn {_from, to} -> [to] end)
      |> Enum.uniq()
      |> Enum.map(fn mod ->
        "  style #{sanitize_id(format_mod(mod))} stroke:#F44336,stroke-width:2px"
      end)

    phantom_style =
      delta.ast_only
      |> MapSet.to_list()
      |> Enum.take(20)
      |> Enum.flat_map(fn {from, _to} -> [from] end)
      |> Enum.uniq()
      |> Enum.map(fn mod ->
        "  style #{sanitize_id(format_mod(mod))} stroke:#9E9E9E,stroke-dasharray: 5 5"
      end)

    summary = [
      "",
      "  %% Summary: #{MapSet.size(delta.both)} confirmed | #{MapSet.size(delta.compiled_only)} hidden (macro/import) | #{MapSet.size(delta.ast_only)} phantom (unused)"
    ]

    Enum.join(
      lines ++ node_lines ++ [""] ++ confirmed_lines ++ [""] ++ hidden_lines ++ [""] ++ phantom_lines ++ [""] ++ hidden_style ++ phantom_style ++ summary,
      "\n"
    )
  end

  @doc """
  Generate a focused delta diagram showing ONLY the differences — hidden and phantom
  edges, without the confirmed ones. This highlights what macros inject and what
  source code declares but doesn't use.
  """
  @spec dependency_delta_only(CompiledGraph.t(), [String.t()]) :: String.t()
  def dependency_delta_only(%CompiledGraph{} = compiled_graph, source_paths) do
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
              from_id = sanitize_id(format_mod(from))
              to_id = sanitize_id(format_mod(to))
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
              from_id = sanitize_id(format_mod(from))
              to_id = sanitize_id(format_mod(to))
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
  defp build_compiled_edges(%CompiledGraph{calls_by_module: calls_by_module, modules: modules}) do
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
    try do
      Module.concat([str])
    rescue
      _ -> nil
    end
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

  defp sanitize_id(str) do
    str
    |> String.replace(".", "_")
    |> String.replace("-", "_")
    |> String.replace(" ", "_")
    |> String.replace("/", "_")
  end
end
