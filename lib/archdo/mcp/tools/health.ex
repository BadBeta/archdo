defmodule Archdo.Mcp.Tools.Health do
  @moduledoc false

  alias Archdo.Runner

  def name, do: "archdo_health"

  def description do
    "Quick project health summary. Returns total findings by severity, " <>
      "top rules by count, performance issue count, and test coverage gap count. " <>
      "Use this for a quick status check before diving into details."
  end

  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "paths" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Paths to analyze. Default: [\"lib\"]."
        }
      },
      "additionalProperties" => false
    }
  end

  def call(args) when is_map(args) do
    paths = Map.get(args, "paths", ["lib"])
    files = Archdo.collect_files(paths)
    diagnostics = Runner.analyze_with_graph(files, [])

    by_severity = Enum.group_by(diagnostics, & &1.severity)

    by_rule =
      diagnostics
      |> Enum.group_by(fn d -> {d.rule_id, d.title} end)
      |> Enum.map(fn {{id, title}, diags} ->
        %{rule_id: id, title: title, count: length(diags)}
      end)
      |> Enum.sort_by(& &1.count, :desc)

    perf_count = Enum.count(diagnostics, fn d -> :perf in Map.get(d, :tags, []) end)

    {:ok,
     %{
       summary: %{
         errors: length(Map.get(by_severity, :error, [])),
         warnings: length(Map.get(by_severity, :warning, [])),
         infos: length(Map.get(by_severity, :info, [])),
         total: length(diagnostics),
         performance_issues: perf_count
       },
       top_rules: Enum.take(by_rule, 10),
       health_grade: grade(diagnostics, files)
     }}
  end

  defp grade(diagnostics, files) do
    file_count = length(files)
    error_count = Enum.count(diagnostics, &(&1.severity == :error))
    warning_count = Enum.count(diagnostics, &(&1.severity == :warning))

    ratio = (error_count * 3 + warning_count) / max(file_count, 1)

    cond do
      error_count > 0 -> "D"
      ratio > 2.0 -> "C"
      ratio > 0.5 -> "B"
      ratio > 0.1 -> "A"
      true -> "A+"
    end
  end
end
