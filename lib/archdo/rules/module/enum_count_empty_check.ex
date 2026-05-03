defmodule Archdo.Rules.Module.EnumCountEmptyCheck do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.47"

  @impl true
  def description, do: "Enum.count/length for empty check — O(n) where O(1) alternatives exist"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_count_checks(ast, file)
    end
  end

  defp find_count_checks(ast, file) do
    length_checks = find_length_checks(ast, file)
    enum_count_checks = find_enum_count_checks(ast, file)
    length_checks ++ enum_count_checks
  end

  # length(x) == 0, length(x) > 0, length(x) != 0
  defp find_length_checks(ast, file) do
    ast
    |> AST.find_all(fn
      {op, _, [{:length, _, [_]}, zero]} when op in [:==, :!=, :>] ->
        AST.zero_literal?(zero)

      {op, _, [zero, {:length, _, [_]}]} when op in [:==, :!=, :<] ->
        AST.zero_literal?(zero)

      _ ->
        false
    end)
    |> Enum.map(fn {op, meta, _} ->
      build_diagnostic(file, AST.line(meta), :length, op)
    end)
  end

  # Enum.count(x) == 0, Enum.count(x) > 0, Enum.count(x) != 0
  defp find_enum_count_checks(ast, file) do
    ast
    |> AST.find_all(fn
      {op, _, [enum_count_call, zero]} when op in [:==, :!=, :>] ->
        enum_count?(enum_count_call) and AST.zero_literal?(zero)

      {op, _, [zero, enum_count_call]} when op in [:==, :!=, :<] ->
        enum_count?(enum_count_call) and AST.zero_literal?(zero)

      _ ->
        false
    end)
    |> Enum.map(fn {op, meta, _} ->
      build_diagnostic(file, AST.line(meta), :enum_count, op)
    end)
  end

  defp enum_count?({{:., _, [{:__aliases__, _, [:Enum]}, :count]}, _, [_]}), do: true
  defp enum_count?(_), do: false

  defp build_diagnostic(file, line, kind, op) do
    func =
      case kind do
        :length -> "length/1"
        :enum_count -> "Enum.count/1"
      end

    suggestion =
      case op do
        :== -> "use `match?([], list)` or `Enum.empty?/1`"
        :> -> "use `match?([_ | _], list)` for non-empty check"
        :!= -> "use `match?([_ | _], list)` for non-empty check"
        :< -> "depends on side — check for empty or non-empty"
      end

    Diagnostic.info("6.47",
      title: "Collection empty check via #{func}",
      message: "#{func} #{op} 0 traverses the entire collection — #{suggestion}",
      why:
        "Both length/1 and Enum.count/1 traverse the entire list to count elements (O(n)). " <>
          "To check if a list is empty or non-empty, pattern match in O(1): " <>
          "`match?([_ | _], list)` for non-empty, `match?([], list)` for empty.",
      alternatives: [
        Fix.new(
          summary: "Pattern match instead of counting",
          detail:
            "`length(x) == 0` -> `match?([], x)` or `Enum.empty?(x)`\n" <>
              "`length(x) > 0` -> `match?([_ | _], x)`",
          applies_when: "Checking whether a collection is empty or non-empty."
        )
      ],
      tags: [:perf],
      file: file,
      line: line
    )
  end
end
