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

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc """
  Project-level analysis. Returns one Diagnostic per unanchored module.
  Test files are excluded — they're driven by ExUnit.run, not the
  production anchor set.
  """
  @spec analyze_project([{String.t(), Macro.t()}]) :: [Diagnostic.t()]
  def analyze_project(file_asts) do
    production_asts = Enum.reject(file_asts, fn {file, _} -> AST.test_file?(file) end)

    anchors = AnchorSet.compute(production_asts)
    graph = Graph.build(production_asts)
    closure = AnchorSet.closure(anchors, graph)

    for {file, ast} <- production_asts,
        module = AST.extract_module_name(ast),
        module != "Unknown",
        not MapSet.member?(closure, module) do
      build_diagnostic(module, file)
    end
  end

  defp build_diagnostic(module, file) do
    Diagnostic.info("CE-30",
      title: "Unanchored module — not reachable from any anchor",
      message:
        "Module #{module} is not transitively reachable from any anchor " <>
          "(Phoenix route, Mix task, supervised process, public API, @archdo_anchor)",
      why:
        "The code adds maintenance load, search-result noise, refactor friction, and " <>
          "dependency surface without contributing to any externally-visible behaviour. " <>
          "This is the most common form of unjustified code in LLM-generated and " <>
          "exploratory codebases — scaffolding built without wiring it to a route, " <>
          "job, or task.\n\n" <>
          "Severity is :info (not :warning) because the static closure is conservative: " <>
          "modules supervised under nested DynamicSupervisors, called via `apply/3` or " <>
          "runtime config, reached via `:erpc`, or wired through macros aren't visible " <>
          "to the AST-only walk. Verify with compiled-mode analysis before treating " <>
          "any individual finding as deletable, OR mark with @archdo_anchor when the " <>
          "entry path is genuinely dynamic.",
      alternatives: [
        Fix.new(
          summary: "Delete the module",
          detail: "If nothing depends on it through any anchor path, remove it.",
          applies_when: "The module is genuinely unused."
        ),
        Fix.new(
          summary: "Add the missing anchor",
          detail:
            "If the module is reached via a path the static analyzer can't see " <>
              "(`apply/3`, `Code.ensure_loaded/1`, runtime config, `:erpc` from " <>
              "another node), declare it: `@archdo_anchor \"<reason>\"`. Or wire " <>
              "it to an actual route, supervised process, or Mix task.",
          applies_when: "The module IS used but the call path is dynamic."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-30"],
      context: %{module: module},
      file: file,
      line: 1
    )
  end
end
