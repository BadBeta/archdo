defmodule Archdo.Rules.Compiled.ChangeRisk do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Compiled.Graph

  @impl true
  def id, do: "1.20"

  @impl true
  def description, do: "Module change has high blast radius — many transitive dependents"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  # Flag modules where total transitive impact exceeds this
  @total_threshold 20
  # Flag modules where depth exceeds this
  @depth_threshold 3

  @spec analyze_compiled(Graph.t()) :: [Diagnostic.t()]
  def analyze_compiled(%Graph{modules: modules} = graph) do
    modules
    |> Map.keys()
    |> Enum.map(fn mod -> Graph.blast_radius(graph, mod) end)
    |> Enum.filter(fn report ->
      report.total_affected > @total_threshold or
        report.max_depth > @depth_threshold
    end)
    |> Enum.sort_by(& &1.risk_score, :desc)
    |> Enum.map(&build_diagnostic/1)
  end

  defp build_diagnostic(report) do
    mod_name = AST.module_name(report.module)

    depth_by_level =
      report.transitive_dependents
      |> Enum.sort_by(fn {depth, _mods} -> depth end)
      |> Enum.map(fn {depth, mods} -> "depth #{depth}: #{length(mods)} modules" end)
      |> Enum.join(", ")

    struct_note =
      case report.defines_struct do
        true -> " Defines a struct (struct changes cause broader recompilation)."
        false -> ""
      end

    behaviour_note =
      case report.defines_behaviour do
        true -> " Defines behaviour callbacks (callback changes affect all implementations)."
        false -> ""
      end

    Diagnostic.warning("1.20",
      title: "High change blast radius",
      message:
        "#{mod_name} — changing this module affects #{report.total_affected} modules " <>
          "across #{report.max_depth} dependency layers (risk score: #{Float.round(report.risk_score, 1)})",
      why:
        "Changes to this module cascade through #{report.total_affected} transitive dependents. " <>
          "Impact by layer: #{depth_by_level}." <>
          struct_note <>
          behaviour_note <>
          " High blast radius means changes need careful review, " <>
          "thorough testing, and ideally should be batched to minimize disruption.",
      alternatives: [
        Fix.new(
          summary: "Split stable parts from volatile parts",
          detail:
            "Move struct definitions, type specs, and rarely-changing interfaces " <>
              "into a stable module (e.g., #{mod_name}.Types). Keep business logic " <>
              "that changes frequently in the main module. Dependents that only need " <>
              "the types won't recompile when logic changes.",
          applies_when: "The module mixes stable types with volatile logic."
        ),
        Fix.new(
          summary: "Introduce a behaviour boundary",
          detail:
            "Define a behaviour with the public interface. Dependents call through " <>
              "the behaviour — implementation changes don't trigger recompilation of callers.",
          applies_when: "Many dependents use the same subset of functions."
        ),
        Fix.new(
          summary: "Accept the risk with testing",
          detail:
            "If the module is a core utility (like AST helpers), the blast radius is " <>
              "inherent to its role. Ensure comprehensive tests cover all dependents. " <>
              "#{report.functions_called} of the module's exports are called externally.",
          applies_when: "The module's central role is by design, not by accident."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#1.20"],
      context: %{
        module: mod_name,
        total_affected: report.total_affected,
        max_depth: report.max_depth,
        risk_score: Float.round(report.risk_score, 1),
        defines_struct: report.defines_struct,
        defines_behaviour: report.defines_behaviour
      },
      file: "lib",
      line: 0
    )
  end

end
