defmodule Archdo.Rules.Compiled.CompileDependencyHotspot do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Compiled
  alias Archdo.Compiled.Graph

  @impl true
  def id, do: "1.18"

  @impl true
  def description, do: "Module depended on by many others — compile dependency hotspot"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  # Flag modules with more than this many dependents
  @dependent_threshold 10

  @spec analyze_compiled(Graph.t()) :: [Diagnostic.t()]
  def analyze_compiled(%Graph{modules: modules} = graph) do
    modules
    |> Map.keys()
    |> Enum.map(fn mod ->
      dependents = Compiled.module_dependents(graph, mod)
      {mod, length(dependents), dependents}
    end)
    |> Enum.filter(fn {_mod, count, _deps} -> count > @dependent_threshold end)
    |> Enum.sort_by(fn {_mod, count, _deps} -> count end, :desc)
    |> Enum.map(fn {mod, count, dependents} ->
      build_diagnostic(mod, count, dependents)
    end)
  end

  defp build_diagnostic(module, dependent_count, dependents) do
    mod_name = AST.module_name(module)

    sample =
      dependents
      |> Enum.take(5)
      |> Enum.map_join(", ", &AST.module_name/1)

    Diagnostic.info("1.18",
      title: "Compile dependency hotspot",
      message:
        "#{mod_name} is depended on by #{dependent_count} modules" <>
          " — changes trigger widespread recompilation",
      why:
        "Modules that many others depend on become recompilation bottlenecks. " <>
          "When you change this module, all #{dependent_count} dependents must recompile. " <>
          "Consider splitting stable parts (types, structs) from volatile parts " <>
          "(business logic) so that changes to logic don't force dependents to recompile.",
      alternatives: [
        Fix.new(
          summary: "Split stable types from volatile logic",
          detail:
            "Move struct definitions and type specs into a separate module " <>
              "(e.g., #{mod_name}.Types) that changes rarely. Dependents that only " <>
              "need the types can depend on the stable module.",
          applies_when: "The module contains both data structures and business logic."
        ),
        Fix.new(
          summary: "Introduce a behaviour interface",
          detail:
            "Define a behaviour with the public callbacks, have dependents " <>
              "call through the behaviour. Implementation changes won't trigger recompilation.",
          applies_when: "Dependents use the module through a well-defined interface."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#1.18"],
      context: %{
        module: mod_name,
        dependent_count: dependent_count,
        sample_dependents: sample
      },
      file: "lib",
      line: 0
    )
  end
end
