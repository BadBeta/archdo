defmodule Archdo.Rules.CE.UnanchoredModule do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-30. Modules that exist but aren't
  # transitively reachable from any anchor (Phoenix route, Mix task,
  # supervised process, public API, `@archdo_anchor`). Such modules add
  # maintenance load, search-result noise, refactor friction, and
  # dependency surface without contributing to externally-visible
  # behaviour. Common LLM and exploratory-codebase failure mode.

  alias Archdo.{AnchorSet, AST, Diagnostic, Fix, Graph}

  @impl true
  def id, do: "CE-30"

  @impl true
  def description, do: "Module not reachable from any anchor (route, task, supervisor, ...)"

  @doc """
  Project-level analysis. Returns one Diagnostic per unanchored module.
  Test files are excluded — they're driven by ExUnit.run, not the
  production anchor set.

  When `opts[:compiled_reached_modules]` is a `MapSet` of module atoms,
  any candidate module present in the set is suppressed: the compiled
  call graph (post-macro-expansion) shows the module IS reached, so an
  AST-only orphan finding would be a false positive. Modules wired in
  via `use Foo`, `import Foo`, or any other macro-injected call show up
  as reached in the compiled graph but not in the AST graph this rule
  walks. See `Archdo.Compiled.module_dependents/2`.
  """
  @spec analyze_project([{String.t(), Macro.t()}], keyword()) :: [Diagnostic.t()]
  def analyze_project(file_asts, opts \\ []) do
    production_asts = Enum.reject(file_asts, fn {file, _} -> AST.test_file?(file) end)

    library? = Keyword.get(opts, :library?, false)

    anchors =
      production_asts
      |> AnchorSet.compute()
      |> add_library_public_anchors(production_asts, library?)
      |> add_behaviour_implementor_anchors(production_asts, library?)
      |> add_behaviour_definition_anchors(production_asts)

    graph = Graph.build(production_asts)
    closure = AnchorSet.closure(anchors, graph)
    reached_via_compiled = Keyword.get(opts, :compiled_reached_modules, MapSet.new())

    for {file, ast} <- production_asts,
        module = AST.extract_module_name(ast),
        module != "Unknown",
        not MapSet.member?(closure, module),
        not reached_via_compiled?(module, reached_via_compiled) do
      build_diagnostic(module, file)
    end
  end

  # In a library project (mix.exs has package/0), every module that
  # ISN'T marked `@moduledoc false` is part of the public API and is
  # therefore anchored — external consumers reach it directly. Without
  # this, a Hex library like Floki has no anchors at all (no Phoenix
  # route, no Application, no Mix.Task) and every public module
  # flags. Validated against Floki: 30 → ~1 CE-30 findings.
  #
  # Library status is threaded via opts[:library?] (computed once by
  # the runner) rather than auto-detected per-rule. Auto-detection
  # via find_mix_root is unreliable in unit tests that use synthetic
  # file paths — find_mix_root walks the filesystem and may pick up
  # the test runner's own mix.exs.
  defp add_library_public_anchors(anchors, production_asts, true) do
    public_modules =
      for {_file, ast} <- production_asts,
          module = AST.extract_module_name(ast),
          module != "Unknown",
          not AST.internal_module?(ast),
          into: MapSet.new(),
          do: module

    MapSet.union(anchors, public_modules)
  end

  defp add_library_public_anchors(anchors, _production_asts, _not_library), do: anchors

  # Behaviour-implementor modules are pluggable adapters reached via
  # runtime config (`Application.get_env(:my_app, :backend)`) — the
  # static AST graph can't see those edges. Anchor any module that
  # declares `@behaviour Foo` where Foo is a project-defined
  # behaviour. Validated against Floki — clears
  # Floki.HTMLParser.{FastHtml,Html5ever,Mochiweb} which are dispatched
  # via Application config.
  #
  # Library-context only: in an application, behaviour implementors
  # are typically reached via supervised processes or explicit
  # registration that the AST graph CAN see, so anchoring them
  # blindly there would over-suppress.
  defp add_behaviour_implementor_anchors(anchors, production_asts, true) do
    project_callbacks = AST.collect_behaviour_callbacks(production_asts)

    implementor_modules =
      for {_file, ast} <- production_asts,
          module = AST.extract_module_name(ast),
          module != "Unknown",
          implements_project_behaviour?(ast, project_callbacks),
          into: MapSet.new(),
          do: module

    MapSet.union(anchors, implementor_modules)
  end

  defp add_behaviour_implementor_anchors(anchors, _production_asts, _not_library), do: anchors

  # When module A declares `@behaviour B`, module B is part of A's
  # compile-time interface — deleting B would break A. Anchor every
  # B referenced by `@behaviour B` from any module in scope. Catches
  # the `@moduledoc false` behaviour-definition case where the
  # definition module declares `@callback`s but is never directly
  # called — its purpose IS to be the contract.
  #
  # Independent of library mode: applies in apps too (a behaviour
  # def referenced from `@behaviour` is reachable regardless).
  defp add_behaviour_definition_anchors(anchors, production_asts) do
    referenced_behaviours =
      for {_file, ast} <- production_asts,
          mod_name <- declared_behaviour_targets(ast),
          into: MapSet.new(),
          do: mod_name

    MapSet.union(anchors, referenced_behaviours)
  end

  # Walk a module AST collecting every `@behaviour Mod.Name` target as
  # a string. Both bare `@behaviour Foo` and the literal_encoder-wrapped
  # form parse as `{:@, _, [{:behaviour, _, [{:__aliases__, _, parts}]}]}`.
  defp declared_behaviour_targets(ast) do
    {_, refs} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{:behaviour, _, [{:__aliases__, _, parts}]}]} = node, acc
        when is_list(parts) ->
          {node, [Enum.map_join(parts, ".", &Atom.to_string/1) | acc]}

        node, acc ->
          {node, acc}
      end)

    refs
  end

  defp implements_project_behaviour?(ast, project_callbacks) do
    callbacks = AST.module_implemented_callbacks(ast, project_callbacks)
    MapSet.size(callbacks) > 0
  end

  # §§ elixir-implementing: §5.2 — multi-clause head, no if/else.
  # The closure contains module-name strings; the compiled-graph set
  # contains module atoms. Convert and compare.
  defp reached_via_compiled?(module_name, %MapSet{} = set) when is_binary(module_name) do
    case safe_to_existing_atom(module_name) do
      nil -> false
      atom -> MapSet.member?(set, atom)
    end
  end

  defp safe_to_existing_atom(name) do
    String.to_existing_atom("Elixir." <> name)
  rescue
    ArgumentError -> nil
  end

  defp build_diagnostic(module, file) do
    Diagnostic.info("CE-30",
      title: "Unanchored module — not reachable from any anchor",
      message:
        "Module #{module} is not transitively reachable from any anchor " <>
          "(Phoenix route, Mix task, supervised process, public API, " <>
          "@archdo_anchor) in the source AST. NOTE: this is an AST-only walk " <>
          "and therefore CANNOT see modules wired in via macros — `use Foo`, " <>
          "Phoenix routes generated from `pipe_through`, Ecto schemas reached " <>
          "via `Repo` calls, channel handlers wired by `socket/3`, etc. — nor " <>
          "modules invoked dynamically (`apply/3`, runtime config, `:erpc`). " <>
          "Re-run with `mix archdo --compiled` and check the compiled call " <>
          "graph (rule 1.25 `orphan_module`) before treating this finding as " <>
          "deletable; the compiled graph captures macro-expanded edges.",
      why:
        "The code adds maintenance load, search-result noise, refactor friction, and " <>
          "dependency surface without contributing to any externally-visible behaviour. " <>
          "This is the most common form of unjustified code in LLM-generated and " <>
          "exploratory codebases — scaffolding built without wiring it to a route, " <>
          "job, or task.\n\n" <>
          "Severity is :info (not :warning) because the static closure is conservative " <>
          "by design. The macro blind spot is the dominant false-positive source: " <>
          "every `use Phoenix.Channel`, every `field` macro in an Ecto schema, every " <>
          "`Plug.Builder` `plug/1` reference, and every `defmacro`-injected call edge " <>
          "is invisible to AST analysis. Modules supervised under nested " <>
          "DynamicSupervisors, called via `apply/3` or runtime config, or reached " <>
          "via `:erpc` from another node are also invisible.\n\n" <>
          "When `mix archdo --compiled` is run alongside, this rule cross-suppresses " <>
          "findings whose module HAS incoming edges in the compiled call graph " <>
          "(those edges are the proof macros / runtime dispatch wired the module). " <>
          "Without `--compiled`, the rule has no signal beyond the AST and " <>
          "individual findings should be verified manually OR marked with " <>
          "`@archdo_anchor` when the entry path is dynamic.",
      alternatives: [
        Fix.new(
          summary: "Run `mix archdo --compiled` and cross-check rule 1.25",
          detail:
            "The compiled-mode pipeline reads `.beam` files where macros have already " <>
              "expanded — incoming edges from `use`, `defmacro`, `Phoenix.Router`, " <>
              "`Ecto.Schema` etc. are visible. If `1.25 orphan_module` does not fire " <>
              "on the same module, the AST-only finding is a macro-driven false " <>
              "positive and should be ignored. When CE-30 is run with `--compiled`, " <>
              "this cross-suppression happens automatically.",
          applies_when: "The project compiles cleanly and `mix archdo --compiled` is available."
        ),
        Fix.new(
          summary: "Mark the entry path with @archdo_anchor",
          detail:
            "If the module is reached via a path the static analyzer can't see " <>
              "(`apply/3`, `Code.ensure_loaded/1`, runtime config, `:erpc` from " <>
              "another node, custom DSL macros), declare the entry: " <>
              "`@archdo_anchor \"<reason>\"`. Anchors short-circuit the closure walk.",
          applies_when:
            "The module IS used but the call path is dynamic and not detectable by --compiled."
        ),
        Fix.new(
          summary: "Delete the module",
          detail:
            "If nothing depends on it through any anchor path AND `1.25 orphan_module` " <>
              "also fires on the compiled graph, remove it. Both rules agreeing is the " <>
              "strongest signal that the module is genuinely unused.",
          applies_when: "Both AST and compiled-graph analysis agree the module is orphan."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-30"],
      context: %{module: module},
      file: file,
      line: 1
    )
  end
end
