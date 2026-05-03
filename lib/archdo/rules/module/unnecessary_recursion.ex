defmodule Archdo.Rules.Module.UnnecessaryRecursion do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.21"

  @impl true
  def description, do: "Manual recursion over a list — prefer Enum/Stream functions"

  @impl true
  def analyze(file, ast, _opts) do
    run_analysis(AST.test_file?(file), file, ast)
  end

  defp run_analysis(true, _file, _ast), do: []
  defp run_analysis(false, file, ast), do: find_list_recursion(file, ast)

  defp find_list_recursion(file, ast) do
    fns = AST.extract_functions(ast, :all)

    fns
    |> Enum.group_by(fn {name, arity, _, _, _} -> {name, arity} end)
    |> Enum.flat_map(fn {{name, arity}, clauses} ->
      check_list_recursion(file, name, arity, clauses)
    end)
  end

  defp check_list_recursion(file, name, arity, clauses) do
    # Pattern: one clause matches [head | tail] and calls self with tail,
    # another clause matches [] as base case.
    matches = head_tail_recursion?(clauses, name, arity) and has_empty_base?(clauses)
    emit_recursion_diag(matches, file, name, arity, clauses)
  end

  defp head_tail_recursion?(clauses, name, arity) do
    Enum.any?(clauses, &head_tail_recurses?(&1, name, arity))
  end

  defp head_tail_recurses?({_, _, _, args, body}, name, arity) do
    args != nil and matches_head_tail?(args) and body != nil and
      calls_self_with_tail?(body, name, arity)
  end

  defp has_empty_base?(clauses), do: Enum.any?(clauses, &empty_base_clause?/1)

  defp empty_base_clause?({_, _, _, args, _body}),
    do: args != nil and matches_empty_list?(args)

  defp emit_recursion_diag(false, _file, _name, _arity, _clauses), do: []

  defp emit_recursion_diag(true, file, name, arity, clauses) do
    meta = clauses |> Enum.map(fn {_, _, m, _, _} -> m end) |> List.first([])

    [
      Diagnostic.info("6.21",
        title: "Manual list recursion",
        message: "#{name}/#{arity} manually recurses over a list — Enum/Stream likely suffices",
        why:
          "Elixir's Enum module handles list iteration with map, reduce, filter, flat_map, " <>
            "and 50+ other functions. Manual recursion with [head | tail] pattern is more " <>
            "code, harder to read, and easy to get wrong (non-tail position, missing base " <>
            "case). Use recursion only for tree traversal, early termination with complex " <>
            "state, or when you need multiple accumulators.",
        alternatives: [
          Fix.new(
            summary: "Replace with Enum.map/2",
            detail: "If transforming each element: `Enum.map(list, &transform/1)`",
            applies_when: "Each element is independently transformed."
          ),
          Fix.new(
            summary: "Replace with Enum.reduce/3",
            detail:
              "If accumulating a result: `Enum.reduce(list, initial, fn item, acc -> ... end)`",
            applies_when: "Building up a single result from the list."
          ),
          Fix.new(
            summary: "Replace with Enum.flat_map/2 or Enum.filter/2",
            detail: "If filtering or expanding: use the appropriate Enum function.",
            applies_when: "Filtering or expanding elements."
          ),
          Fix.new(
            summary: "Keep recursion if traversing a tree or need early exit",
            detail:
              "Recursion is the right tool for trees, graphs, and complex multi-accumulator " <>
                "patterns. If this is one of those, the rule is a false positive.",
            applies_when: "The data structure is not a flat list."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#6.21"],
        context: %{function: "#{name}/#{arity}"},
        file: file,
        line: AST.line(meta)
      )
    ]
  end

  # Matches [head | tail] pattern in function arguments
  defp matches_head_tail?(args) when is_list(args) do
    Enum.any?(args, fn
      [{:|, _, _}] -> true
      {:|, _, _} -> true
      _ -> false
    end)
  end

  defp matches_head_tail?(_), do: false

  # Matches [] in function arguments (base case)
  defp matches_empty_list?(args) when is_list(args) do
    Enum.any?(args, fn
      [] -> true
      {:__block__, _, [[]]} -> true
      _ -> false
    end)
  end

  defp matches_empty_list?(_), do: false

  defp calls_self_with_tail?(body, name, arity), do: AST.has_self_call?(body, name, arity)
end
