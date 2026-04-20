defmodule Archdo.Rules.Module.BrokenTailRecursion do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.22"

  @impl true
  def description,
    do: "Recursive function appears tail-recursive but TCO is broken by try/rescue or post-call operations"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      find_broken_tco(file, ast)
    end
  end

  defp find_broken_tco(file, ast) do
    fns = AST.extract_functions(ast, :all)

    fns
    |> Enum.group_by(fn {name, arity, _, _, _} -> {name, arity} end)
    |> Enum.flat_map(fn {{name, arity}, clauses} ->
      check_tco(file, name, arity, clauses)
    end)
  end

  defp check_tco(file, name, arity, clauses) do
    # Only check functions that ARE recursive (have self-calls)
    is_recursive =
      Enum.any?(clauses, fn {_, _, _, _, body} ->
        body != nil and has_self_call?(body, name, arity)
      end)

    if not is_recursive do
      []
    else
      breakers =
        clauses
        |> Enum.flat_map(fn
          {_, _, _, _, nil} -> []
          {_, _, _, _, body} -> find_tco_breakers(body, name, arity)
        end)

      case breakers do
        [] ->
          []

        [first_breaker | _] ->
          meta =
            clauses
            |> Enum.map(fn {_, _, m, _, _} -> m end)
            |> List.first([])

          [build_diagnostic(file, name, arity, meta, first_breaker)]
      end
    end
  end

  defp find_tco_breakers(body, name, arity) do
    checks = [
      {:try_rescue, &self_call_inside_try?/3},
      {:pipe_after, &self_call_piped?/3},
      {:binary_op, &self_call_in_binary_op?/3}
    ]

    for {breaker, check_fn} <- checks,
        check_fn.(body, name, arity),
        do: breaker
  end

  # Recursive call inside try/rescue/catch — BEAM keeps frame for exception handling
  defp self_call_inside_try?(body, name, arity) do
    AST.contains?(body, fn
      {:try, _, [kw]} when is_list(kw) ->
        try_body = Keyword.get(kw, :do)
        has_rescue = Keyword.has_key?(kw, :rescue) or Keyword.has_key?(kw, :catch)
        has_rescue and try_body != nil and has_self_call?(try_body, name, arity)

      _ ->
        false
    end)
  end

  # Recursive call piped into another function: recurse(t, acc) |> something()
  defp self_call_piped?(body, name, arity) do
    AST.contains?(body, fn
      {:|>, _, [inner, _]} ->
        has_self_call_direct?(inner, name, arity)

      _ ->
        false
    end)
  end

  # Recursive call as operand: recurse(t, acc) <> suffix
  defp self_call_in_binary_op?(body, name, arity) do
    AST.contains?(body, fn
      {op, _, [left, _right]} when op in [:<>, :++, :+, :-, :*, :/] ->
        has_self_call_direct?(left, name, arity)

      _ ->
        false
    end)
  end

  # Direct self-call (not nested in sub-expressions)
  defp has_self_call_direct?({name, _, args}, name, arity)
       when is_list(args) and length(args) == arity,
       do: true

  defp has_self_call_direct?(_, _, _), do: false

  defp has_self_call?(body, name, arity), do: AST.has_self_call?(body, name, arity)

  defp build_diagnostic(file, name, arity, meta, breaker) do
    reason =
      case breaker do
        :try_rescue ->
          "try/rescue/catch wraps the recursive call — BEAM keeps the stack frame for exception handling"

        :pipe_after ->
          "the recursive call is piped into another function — the pipe operation runs after return"

        :binary_op ->
          "the recursive call is an operand in an expression — the operation runs after return"
      end

    Diagnostic.warning("6.22",
      title: "Broken tail-call optimization",
      message: "#{name}/#{arity} looks tail-recursive but TCO is defeated: #{reason}",
      why:
        "Tail-call optimization (TCO) only works when the recursive call is the very last " <>
          "expression evaluated. Three patterns silently break it:\n" <>
          "1. try/rescue/catch — BEAM must keep the frame to unwind on exception\n" <>
          "2. Pipe after call — `recurse(t, acc) |> IO.inspect()` runs pipe after return\n" <>
          "3. Binary ops — `recurse(t, acc) <> suffix` runs concat after return\n" <>
          "Without TCO, each recursive call adds a stack frame. The function works on small " <>
          "input but crashes with stack overflow on large data.",
      alternatives: [
        Fix.new(
          summary: "Move try/rescue outside the recursive function",
          detail:
            "Wrap the initial call in try/rescue, not the recursive step. Or handle " <>
              "errors per-element with a case and skip bad elements.",
          applies_when: "try/rescue is breaking TCO."
        ),
        Fix.new(
          summary: "Remove post-call operations",
          detail:
            "Move IO.inspect/tap/logging to before the recursive call, or use " <>
              "tap() which doesn't affect the return value.",
          applies_when: "A pipe or operation follows the recursive call."
        ),
        Fix.new(
          summary: "Use Enum functions instead of recursion",
          detail:
            "Enum.map/reduce/flat_map handle iteration with proper stack management.",
          applies_when: "The recursion can be expressed as Enum operations."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.22"],
      context: %{function: "#{name}/#{arity}", breaker: breaker},
      file: file,
      line: AST.line(meta)
    )
  end
end
