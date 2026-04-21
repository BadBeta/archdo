defmodule Archdo.Rules.Module.SingleClauseWith do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.41"

  @impl true
  def description, do: "Single-clause `with` should be a `case` instead"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_single_clause_withs(file, ast)
    end
  end

  defp find_single_clause_withs(file, ast) do
    ast
    |> AST.find_all(fn
      {:with, _meta, _clauses} -> true
      _ -> false
    end)
    |> Enum.flat_map(fn {:with, meta, clauses} ->
      arrow_count = count_arrow_clauses(clauses)

      case arrow_count == 1 do
        true -> [build_diagnostic(file, AST.line(meta))]
        false -> []
      end
    end)
  end

  defp count_arrow_clauses(clauses) when is_list(clauses) do
    Enum.count(clauses, fn
      {:<-, _, _} -> true
      _ -> false
    end)
  end

  defp count_arrow_clauses(_), do: 0

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.41",
      title: "Single-clause with",
      message: "`with` has only one `<-` clause — use `case` instead",
      why:
        "The `with` construct is designed for chaining multiple operations " <>
          "that may fail. A single-clause `with` is equivalent to a `case` " <>
          "but harder to read. Use `case` for a single pattern match, and " <>
          "reserve `with` for 2+ chained operations.",
      alternatives: [
        Fix.new(
          summary: "Replace with `case`",
          detail:
            "Convert `with {:ok, val} <- expr do ... end` to " <>
              "`case expr do {:ok, val} -> ... end`.",
          applies_when: "There is exactly one `<-` clause."
        ),
        Fix.new(
          summary: "Add more clauses to the `with`",
          detail: "If additional operations are planned, chain them with more `<-` clauses.",
          applies_when: "The code is incomplete and more steps will be added."
        )
      ],
      file: file,
      line: line
    )
  end
end
