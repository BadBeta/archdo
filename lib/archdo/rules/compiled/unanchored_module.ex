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

  alias Archdo.{Compiled, Diagnostic, Fix, Graph}

  @impl true
  def id, do: "1.26"

  @impl true
  def description,
    do: "Module not anchor-reachable in the Compiled call graph (post-macro-expansion)"

  @impl true
  def analyze(_file, _ast, _opts), do: []

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

    case MapSet.size(anchors) do
      0 -> []
      _ -> find_unanchored_diagnostics(graph, anchors, opts)
    end
  end

  defp find_unanchored_diagnostics(graph, anchors, opts) do
    deps = build_deps_map(graph, opts)

    deps
    |> find_unanchored(anchors)
    |> Enum.reject(&excluded?(&1, graph))
    |> Enum.map(&build_diagnostic(&1, graph))
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

  # Union compiled-graph function-call edges with AST `:registry` edges
  # (attribute-list module references like `@phase1_rules [Mod.A, Mod.B]`,
  # which xref doesn't see as call edges). The compiled graph captures
  # macro-expanded edges; the AST registry edges capture attribute-list
  # dispatch. Only the union gives an honest reachability picture.
  defp build_deps_map(graph, opts) do
    base =
      graph
      |> Compiled.modules()
      |> Map.keys()
      |> Map.new(fn mod -> {mod, Compiled.module_dependencies(graph, mod)} end)

    case Keyword.get(opts, :ast_graph) do
      nil -> base
      ast_graph -> merge_registry_edges(base, ast_graph)
    end
  end

  defp merge_registry_edges(base, ast_graph) do
    Enum.reduce(base, base, fn {source_atom, _existing}, acc ->
      registry_targets = registry_edges_for(ast_graph, source_atom)
      Map.update(acc, source_atom, registry_targets, &Enum.uniq(&1 ++ registry_targets))
    end)
  end

  defp registry_edges_for(ast_graph, source_atom) do
    source_name = atom_to_module_name(source_atom)

    ast_graph
    |> Graph.dependencies(source_name)
    |> Enum.filter(fn edge -> Map.get(edge, :type) == :registry end)
    |> Enum.map(fn edge -> module_name_to_atom(edge.target) end)
    |> Enum.reject(&is_nil/1)
  end

  defp atom_to_module_name(atom) when is_atom(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> name -> name
      other -> other
    end
  end

  defp module_name_to_atom(name) when is_binary(name) do
    String.to_existing_atom("Elixir." <> name)
  rescue
    ArgumentError -> nil
  end

  # §§ elixir-implementing: §5.2 — multi-clause head; mirrors the
  # exclusion shape used by 1.25 (orphan_module) so the two rules
  # agree on what counts as an "intentional" zero-edge module.
  defp excluded?(mod, graph) do
    behaviour_definition?(mod, graph) or
      application_entry_point?(mod) or
      test_support_module?(mod)
  end

  defp behaviour_definition?(mod, graph) do
    case Map.get(Compiled.modules(graph), mod) do
      %{callback_fns: [_ | _]} -> true
      _ -> false
    end
  end

  defp application_entry_point?(mod) do
    name = Atom.to_string(mod)
    String.ends_with?(name, ".Application") or String.ends_with?(name, ".MixProject")
  end

  defp test_support_module?(mod) do
    name = Atom.to_string(mod)
    String.contains?(name, ".Support.") or String.contains?(name, "TestHelpers")
  end

  defp build_diagnostic(module, _graph) do
    Diagnostic.info("1.26",
      title: "Module not anchor-reachable in compiled call graph",
      message:
        "Module #{inspect(module)} is not transitively reachable from any anchor " <>
          "(Phoenix route, Mix task, supervised process, public API, @archdo_anchor) " <>
          "even after macros expanded. The compiled call graph captures all macro-" <>
          "injected edges (use, defmacro, Phoenix.Router, Ecto.Schema, Plug.Builder), " <>
          "so a module appearing here is NOT a macro false positive — both AST and " <>
          "compiled walks agree the module is orphan.",
      why:
        "Sister rule to CE-30 (AST anchor reachability) and 1.25 (zero in/out edges). " <>
          "1.26 is stricter than CE-30 (uses post-expansion graph) and looser than " <>
          "1.25 (anchor-reachability vs total isolation). When 1.26 fires, the module " <>
          "is genuinely unwired: no anchor reaches it, no macro injection wires it. " <>
          "Strongest deletion signal of the three.\n\n" <>
          "Severity stays :info — runtime-only paths (`apply/3` from external input, " <>
          "`:erpc` from peer nodes, `Code.ensure_loaded/1`) remain invisible to static " <>
          "analysis even at the compiled level. Mark such entry points with " <>
          "`@archdo_anchor`.",
      alternatives: [
        Fix.new(
          summary: "Delete the module",
          detail:
            "1.26 firing is the strongest static signal that the module is unused. " <>
              "Verify by grepping for the module name across the project (a `:erpc` " <>
              "callsite or runtime config that the analyzer can't see is the only " <>
              "remaining hiding place). If grep is also empty, delete.",
          applies_when:
            "1.25 (orphan_module) and CE-30 (AST anchor) also fire, AND grep finds no references."
        ),
        Fix.new(
          summary: "Mark with @archdo_anchor when the entry path is dynamic",
          detail:
            "Some modules are reached only via runtime mechanisms — `apply/3` from " <>
              "config, `:erpc` from another node, Mix.Task auto-discovery in a custom " <>
              "DSL. Add `@archdo_anchor \"<reason>\"` to the module so the closure " <>
              "walk treats it as anchored.",
          applies_when:
            "The module IS used but only via a runtime path no static analyzer can detect."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#1.26"],
      context: %{module: module},
      file: source_file(module, _graph_unused = nil),
      line: 1
    )
  end

  defp source_file(_module, _graph), do: "(compiled)"
end
