defmodule Archdo.Rules.Compiled.CircularFunctionCalls do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Compiled.Graph

  @impl true
  def id, do: "1.19"

  @impl true
  def description, do: "Function-level circular calls detected via Tarjan's SCC"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @spec analyze_compiled(Graph.t()) :: [Diagnostic.t()]
  def analyze_compiled(%Graph{} = graph) do
    graph
    |> Graph.strongly_connected_components()
    |> Enum.filter(&cross_module_cycle?/1)
    |> Enum.map(&build_diagnostic/1)
  end

  # Only report cycles that span multiple modules — intra-module recursion is normal
  defp cross_module_cycle?(scc) do
    scc
    |> Enum.map(fn {mod, _fun, _arity} -> mod end)
    |> Enum.uniq()
    |> length() > 1
  end

  defp build_diagnostic(scc) do
    cycle_str =
      Enum.map_join(scc, " → ", fn {mod, func, arity} ->
        "#{AST.module_name(mod)}.#{func}/#{arity}"
      end)

    modules_involved =
      scc
      |> Enum.map(fn {mod, _f, _a} -> AST.module_name(mod) end)
      |> Enum.uniq()
      |> Enum.join(", ")

    Diagnostic.warning("1.19",
      title: "Circular function calls",
      message: "Function-level cycle: #{cycle_str}",
      why:
        "A circular call chain between functions in different modules creates tight " <>
          "coupling — you cannot understand, test, or modify any function in the cycle " <>
          "without considering all the others. Module-level cycles (rule 1.3) are a " <>
          "coarser signal; this rule identifies the exact functions involved.",
      alternatives: [
        Fix.new(
          summary: "Break the cycle with a callback or event",
          detail:
            "One module in the cycle should define a behaviour or use PubSub " <>
              "instead of calling back into the other. This decouples the modules.",
          applies_when: "The cycle exists because modules need to notify each other."
        ),
        Fix.new(
          summary: "Extract shared logic into a third module",
          detail:
            "Move the functions that both modules need into a new module that " <>
              "both can depend on, breaking the circular dependency.",
          applies_when: "The cycle exists because of shared logic."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#1.19"],
      context: %{
        cycle: cycle_str,
        modules: modules_involved,
        cycle_length: length(scc)
      },
      file: "lib",
      line: 0
    )
  end
end
