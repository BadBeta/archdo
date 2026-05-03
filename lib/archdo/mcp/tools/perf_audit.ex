defmodule Archdo.Mcp.Tools.PerfAudit do
  @moduledoc false

  alias Archdo.Mcp.Encoder
  alias Archdo.Mcp.Tools.Schemas
  alias Archdo.Runner

  @perf_rules ["6.46", "6.47", "6.48", "6.49", "6.50", "6.51", "6.52", "6.53"]

  def name, do: "archdo_perf_audit"

  def description do
    "Run only performance-related rules and return findings grouped by estimated impact. " <>
      "Covers: string concat in loops (O(n^2)), list operations (O(n) vs O(1)), " <>
      "collection traversal waste, regex recompilation, and data structure misuse. " <>
      "Use this for targeted performance review."
  end

  def input_schema, do: Schemas.paths_only()

  def call(args) when is_map(args) do
    paths = Map.get(args, "paths", ["lib"])
    files = Archdo.collect_files(paths)
    diagnostics = Runner.analyze(files, only: @perf_rules)

    by_impact =
      diagnostics
      |> Enum.group_by(&impact_level/1)
      |> Map.new(fn {level, diags} ->
        {level, %{count: length(diags), findings: Enum.map(diags, &Encoder.diagnostic_to_map/1)}}
      end)

    {:ok,
     %{
       total: length(diagnostics),
       by_impact: by_impact,
       summary: impact_summary(diagnostics)
     }}
  end

  defp impact_level(%{severity: :warning}), do: "high"
  defp impact_level(%{rule_id: "6.46"}), do: "high"
  defp impact_level(%{rule_id: "6.50", title: "List ++ in loop" <> _}), do: "high"
  defp impact_level(%{rule_id: "6.50", title: "Inefficient list append" <> _}), do: "high"
  defp impact_level(%{rule_id: "6.51", title: "Enum.member?" <> _}), do: "high"
  defp impact_level(%{rule_id: "6.51", title: "Enum.filter" <> _}), do: "medium"
  defp impact_level(%{rule_id: "6.51", title: "Enum.sort" <> _}), do: "medium"
  defp impact_level(_), do: "low"

  defp impact_summary(diagnostics) do
    high = Enum.count(diagnostics, &(impact_level(&1) == "high"))
    medium = Enum.count(diagnostics, &(impact_level(&1) == "medium"))
    low = Enum.count(diagnostics, &(impact_level(&1) == "low"))

    %{high: high, medium: medium, low: low}
  end
end
