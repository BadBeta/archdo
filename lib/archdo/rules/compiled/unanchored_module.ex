defmodule Archdo.Rules.Compiled.UnanchoredModule do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — 1.26. Compiled-mode anchor-reachability.
  # Companion to:
  #   - CE-30 (AST-only anchor reachability — misses macro-injected edges)
  #   - 1.25 (orphan_module — zero in/out edges, strictest test)
  # This rule sits between them: walks reachability via the COMPILED
  # call graph (post-macro-expansion) starting from the AST-detected
  # anchor set. A module that fires here is unreached even after all
  # macro expansion — strong signal it's genuinely dead.

  alias Archdo.{AST, Compiled, Diagnostic, Fix, Graph}
  alias Archdo.Rules.Compiled.Helpers

  @impl true
  def id, do: "1.26"

  @impl true
  def description,
    do: "Module not anchor-reachable in the Compiled call graph (post-macro-expansion)"

  @doc """
  Compiled-mode analysis. Requires the AST anchor set to be passed via
  `opts[:ast_anchor_modules]` (a `MapSet` of module atoms). The
  orchestrator (`Archdo.run/2`) builds it once when `--compiled` is
  set and threads it through.

  Without anchor data, returns `[]` — the rule has no signal.
  """
  @spec analyze_compiled(Compiled.t()) :: [Diagnostic.t()]
  def analyze_compiled(graph), do: analyze_compiled(graph, [])

  @spec analyze_compiled(Compiled.t(), keyword()) :: [Diagnostic.t()]
  def analyze_compiled(graph, opts) do
    anchors = Keyword.get(opts, :ast_anchor_modules, MapSet.new())
    library_publics = Keyword.get(opts, :library_public_modules, MapSet.new())
    behav_anchors = compiled_graph_behaviour_anchors(graph)

    # Three sources seed the closure walk:
    #   1. AST anchors (Phoenix routes, Mix tasks, supervised processes,
    #      `@archdo_anchor`)
    #   2. Library publics (Hex package's non-@moduledoc-false modules,
    #      reachable by external consumers we can't see)
    #   3. Behaviour implementors (modules with `@behaviour Mod`, reached
    #      via `apply(mod, callback, args)` from the framework that owns
    #      the behaviour — invisible to static analysis)
    #
    # Without (3), `@moduledoc false` modules called only by behaviour
    # implementors became unreachable: Bandit.Adapter (impl Plug.Conn.Adapter)
    # calls Bandit.Headers, but with Adapter excluded from FINDINGS yet
    # also missing from the CLOSURE, Headers had no path from any seed.
    combined_anchors =
      anchors
      |> MapSet.union(library_publics)
      |> MapSet.union(behav_anchors)

    case MapSet.size(combined_anchors) do
      0 -> []
      _ -> find_unanchored_diagnostics(graph, combined_anchors, opts)
    end
  end

  @doc """
  Pure: extract module atoms that declare `@behaviour Mod` (any) from a
  compiled-graph modules map. Used to seed 1.26's closure walk —
  behaviour implementors are reached via callback dispatch from a
  parent framework, so their outgoing call edges should propagate
  through the closure.

  Public for direct testing.
  """
  @spec behaviour_implementor_anchors(%{module() => map()}) :: MapSet.t(module())
  def behaviour_implementor_anchors(modules_map) when is_map(modules_map) do
    for {mod, %{behaviours: [_ | _]}} <- modules_map,
        into: MapSet.new(),
        do: mod
  end

  # Resolve the modules map from a graph that may be a Compiled.Graph
  # struct (production path) or a bare placeholder (legacy /1 dispatch
  # without opts — see "rule is a no-op without anchor data" test).
  defp compiled_graph_behaviour_anchors(%Archdo.Compiled.Graph{} = graph) do
    behaviour_implementor_anchors(Compiled.modules(graph))
  end

  defp compiled_graph_behaviour_anchors(_), do: MapSet.new()

  defp find_unanchored_diagnostics(graph, anchors, opts) do
    deps = build_deps_map(graph, opts)

    for mod <- find_unanchored(deps, anchors),
        not excluded?(mod, graph),
        do: build_diagnostic(mod)
  end

  # §§ elixir-implementing: §5.5 — pure recursive helpers; the rule's
  # core is testable without constructing a Compiled.t() in tests.

  @doc """
  Pure forward closure over a `module => [outgoing_module_deps]` map,
  starting from `anchors`. Returns the reachable set including the
  anchors themselves. Cycles are handled by visited-set tracking.

  Public for direct testing — the IO shell (`analyze_compiled/2`)
  builds the deps map from `Compiled.module_dependencies/2` and
  delegates here.
  """
  @spec compute_closure(%{module() => [module()]}, MapSet.t(module())) :: MapSet.t(module())
  def compute_closure(deps, anchors) when is_map(deps) and is_struct(anchors, MapSet) do
    walk(deps, MapSet.to_list(anchors), anchors)
  end

  defp walk(_deps, [], visited), do: visited

  defp walk(deps, [m | rest], visited) do
    next =
      deps
      |> Map.get(m, [])
      |> Enum.reject(&MapSet.member?(visited, &1))

    new_visited = Enum.reduce(next, visited, &MapSet.put(&2, &1))
    walk(deps, rest ++ next, new_visited)
  end

  @doc """
  Pure: returns the sorted list of modules present in `deps` that are
  NOT in the anchor closure.
  """
  @spec find_unanchored(%{module() => [module()]}, MapSet.t(module())) :: [module()]
  def find_unanchored(deps, anchors) do
    closure = compute_closure(deps, anchors)

    deps
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(closure, &1))
    |> Enum.sort()
  end

  # Union compiled-graph function-call edges with three AST-side virtual
  # edge types:
  #   - `:registry` edges (attribute-list module references like
  #     `@phase1_rules [Mod.A, Mod.B]`), invisible to xref
  #   - macro-emit edges from `defmacro` bodies that quote calls to
  #     sibling modules (M-fp-F1; the Commanded.Commands.Router →
  #     Dispatcher pattern). The library's compiled BEAM has zero edges
  #     because the call materializes inside the consumer's module.
  #
  # Only the union gives an honest reachability picture.
  defp build_deps_map(graph, opts) do
    base =
      graph
      |> Compiled.modules()
      |> Map.keys()
      |> Map.new(fn mod -> {mod, Compiled.module_dependencies(graph, mod)} end)

    base
    |> maybe_merge_registry_edges(Keyword.get(opts, :ast_graph))
    |> merge_macro_emit_edges(Keyword.get(opts, :macro_emit_edges, %{}))
  end

  defp maybe_merge_registry_edges(base, nil), do: base
  defp maybe_merge_registry_edges(base, ast_graph), do: merge_registry_edges(base, ast_graph)

  defp merge_registry_edges(base, ast_graph) do
    Enum.reduce(base, base, fn {source_atom, _existing}, acc ->
      registry_targets = registry_edges_for(ast_graph, source_atom)
      Map.update(acc, source_atom, registry_targets, &Enum.uniq(&1 ++ registry_targets))
    end)
  end

  @doc """
  Pure: union an existing deps map with macro-emit virtual edges.

  `macro_edges` is `%{module_atom => [module_atom]}` — typically the
  output of `Archdo.AST.MacroEdges.extract/1` per file, then atom-converted
  and merged across the project. Source modules absent from `macro_edges`
  are unchanged.

  Public for direct testing — production callers go through
  `analyze_compiled/2`.
  """
  @spec merge_macro_emit_edges(%{module() => [module()]}, %{module() => [module()]}) ::
          %{module() => [module()]}
  def merge_macro_emit_edges(base, macro_edges) when is_map(base) and is_map(macro_edges) do
    Enum.reduce(macro_edges, base, fn {source, targets}, acc ->
      Map.update(acc, source, targets, &Enum.uniq(&1 ++ targets))
    end)
  end

  defp registry_edges_for(ast_graph, source_atom) do
    source_name = AST.module_name(source_atom)

    for edge <- Graph.dependencies(ast_graph, source_name),
        Graph.edge_of_type?(edge, :registry),
        atom = AST.safe_existing_atom(edge.target),
        not is_nil(atom),
        do: atom
  end

  # §§ elixir-implementing: §5.2 — multi-clause head; mirrors the
  # exclusion shape used by 1.25 (orphan_module) so the two rules
  # agree on what counts as an "intentional" zero-edge module.
  defp excluded?(mod, graph) do
    Helpers.behaviour_definition?(mod, graph) or
      Helpers.behaviour_implementor?(mod, graph) or
      Helpers.application_entry_point?(mod) or
      test_support_module?(mod)
  end

  defp test_support_module?(mod) do
    name = Atom.to_string(mod)
    String.contains?(name, ".Support.") or String.contains?(name, "TestHelpers")
  end

  @doc """
  Builds the `:info`-severity Diagnostic for an unanchored module.

  Public for direct testing — production callers go through
  `analyze_compiled/2`.
  """
  @spec build_diagnostic(module()) :: Diagnostic.t()
  def build_diagnostic(module) do
    Diagnostic.info("1.26",
      title: "Module not anchor-reachable in compiled call graph",
      message:
        "Module #{inspect(module)} is not transitively reachable from any anchor " <>
          "(Phoenix route, Mix task, supervised process, public API, @archdo_anchor) " <>
          "even after macros expanded. The compiled call graph captures most macro-" <>
          "injected edges (use, defmacro, Phoenix.Router, Ecto.Schema, Plug.Builder), " <>
          "but it cannot see calls a library's macros emit into the CONSUMER's " <>
          "compiled module — the library's BEAM has zero edges, the consumer's BEAM " <>
          "has the call. Strong signal, not absolute: combine with grep before deleting.",
      why:
        "Sister rule to CE-30 (AST anchor reachability) and 1.25 (zero in/out edges). " <>
          "1.26 is stricter than CE-30 (uses post-expansion graph) and looser than " <>
          "1.25 (anchor-reachability vs total isolation). When 1.26 fires, the module " <>
          "is unwired AS SCANNED: no anchor reaches it, no macro injection inside the " <>
          "scanned source wires it. Still the strongest deletion signal of the three, " <>
          "but flagged as `:info` because two FP classes remain:\n\n" <>
          "  1. Runtime-only paths — `apply/3` from external input, `:erpc` from peer " <>
          "nodes, `Code.ensure_loaded/1`, Mix.Task auto-discovery in a custom DSL.\n" <>
          "  2. Macros that emit dispatch logic into the CONSUMER's compiled module " <>
          "(e.g. `Commanded.Commands.Router`'s `dispatch_to_aggregate/3` quotes a call " <>
          "to `Commanded.Commands.Dispatcher` — the library's own BEAM has no edge).\n\n" <>
          "Mark such entry points with `@archdo_anchor`.",
      alternatives: [
        Fix.new(
          summary: "Delete the module",
          detail:
            "1.26 firing is the strongest static signal that the module is unused. " <>
              "Verify by grepping for the module name across the project (a `:erpc` " <>
              "callsite, runtime config, or library-scope macro emitting calls into " <>
              "consumer modules is the only remaining hiding place). If grep is also " <>
              "empty, delete.",
          applies_when:
            "1.25 (orphan_module) and CE-30 (AST anchor) also fire, AND grep finds no references."
        ),
        Fix.new(
          summary: "Mark with @archdo_anchor when the entry path is dynamic",
          detail:
            "Some modules are reached only via paths static analysis can't trace:\n" <>
              "  • `apply/3` from runtime config or external input\n" <>
              "  • `:erpc` / `:rpc` calls from another node\n" <>
              "  • `Code.ensure_loaded/1` + `apply/3` plugin discovery\n" <>
              "  • Mix.Task auto-discovery in a custom DSL\n" <>
              "  • Macros in a LIBRARY that quote calls to a sibling module — the " <>
              "compiled call edge materializes inside the consumer's BEAM, not the " <>
              "library's. Example: `Commanded.Commands.Router`'s `dispatch_to_aggregate/3` " <>
              "macro emits a call to `Commanded.Commands.Dispatcher` into the user's " <>
              "router module; scanning the Commanded library in isolation, Dispatcher " <>
              "appears unreachable.\n\n" <>
              "Add `@archdo_anchor \"<reason>\"` to the module so the closure walk " <>
              "treats it as anchored.",
          applies_when:
            "The module IS used but only via a runtime path or macro-emitted-into-consumer call no static analyzer scanning the library in isolation can detect."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#1.26"],
      context: %{module: module},
      file: "(compiled)",
      line: 1
    )
  end
end
