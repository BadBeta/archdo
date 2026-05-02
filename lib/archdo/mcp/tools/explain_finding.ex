defmodule Archdo.Mcp.Tools.ExplainFinding do
  @moduledoc false

  alias Archdo.Runner

  def name, do: "archdo_explain_finding"

  def description do
    "Given a specific file and line, analyze that file and return the finding " <>
      "at or near that line with full context: what's wrong, why it matters, " <>
      "how to fix it, and the actual code at that location. More detailed than " <>
      "archdo_explain_rule because it includes the specific code context."
  end

  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "file" => %{
          "type" => "string",
          "description" => "Path to the file containing the finding."
        },
        "line" => %{
          "type" => "integer",
          "description" => "Line number of the finding."
        }
      },
      "required" => ["file", "line"],
      "additionalProperties" => false
    }
  end

  def call(%{"file" => file, "line" => target_line}) do
    case File.exists?(file) do
      true ->
        diagnostics = Runner.analyze([file], [])

        # Find the diagnostic at or closest to the target line
        case find_nearest(diagnostics, target_line) do
          nil ->
            {:ok,
             %{
               file: file,
               line: target_line,
               finding: nil,
               message: "No finding at or near line #{target_line} in #{file}",
               code_context: read_context(file, target_line)
             }}

          diagnostic ->
            {:ok,
             %{
               file: file,
               line: diagnostic.line,
               finding: %{
                 rule_id: diagnostic.rule_id,
                 severity: diagnostic.severity,
                 title: diagnostic.title,
                 message: diagnostic.message,
                 why: diagnostic.why,
                 fixes:
                   Enum.map(diagnostic.alternatives, fn fix ->
                     %{summary: fix.summary, detail: fix.detail, applies_when: fix.applies_when}
                   end)
               },
               code_context: read_context(file, diagnostic.line)
             }}
        end

      false ->
        {:error, "File not found: #{file}"}
    end
  end

  def call(_), do: {:error, "Missing required arguments: file, line"}

  defp find_nearest([], _target), do: nil

  defp find_nearest(diagnostics, target) do
    Enum.min_by(diagnostics, fn d -> abs(d.line - target) end)
  end

  defp read_context(file, line) do
    case File.read(file) do
      {:ok, content} ->
        lines = String.split(content, "\n")
        start = max(0, line - 4)
        finish = min(length(lines) - 1, line + 3)

        lines
        |> Enum.with_index(1)
        |> Enum.slice(start..finish)
        |> Enum.map_join("\n", fn {text, num} ->
          marker = if num == line, do: "→ ", else: "  "
          "#{marker}#{num}: #{text}"
        end)

      {:error, _} ->
        nil
    end
  end
end
