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

    anchors = AnchorSet.compute(production_asts)
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
