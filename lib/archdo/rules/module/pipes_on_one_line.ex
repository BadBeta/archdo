defmodule Archdo.Rules.Module.PipesOnOneLine do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.62"

  @impl true
  def description, do: "Multiple pipes on a single line — one pipe per line is canonical"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    ast
    |> AST.find_all(&pipe_node?/1)
    |> Enum.map(&pipe_line/1)
    |> Enum.frequencies()
    |> Enum.flat_map(fn
      {line, count} when count >= 2 -> [build_diagnostic(file, line)]
      _ -> []
    end)
  end

  defp pipe_node?({:|>, _, _}), do: true
  defp pipe_node?(_), do: false

  defp pipe_line({:|>, meta, _}), do: AST.line(meta)

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.62",
      title: "Multiple pipes on one line",
      message:
        "Two or more `|>` pipes share this source line. Use one pipe per line — pipelines " <>
          "exist for readability, and inlining defeats that.",
      why:
        "A pipeline is a sequence of transformations on a primary subject. Each step has its " <>
          "own intent. Putting multiple pipes on one line collapses the visual structure and " <>
          "forces the reader to mentally re-parse the chain. The canonical Elixir form is " <>
          "subject on its own line, then one `|>` per step on its own line.",
      alternatives: [
        Fix.new(
          summary: "Break each pipe step onto its own line",
          detail: "list\n|> Enum.map(&format/1)\n|> Enum.join(\", \")",
          applies_when: "Always for chains of 2+ pipes."
        )
      ],
      references: ["elixir-implementing/SKILL.md#5.1"],
      context: %{},
      file: file,
      line: line
    )
  end
end
