defmodule Archdo.Rules.Module.ManualRecursionAsReduce do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.100"

  @impl true
  def description, do: "List recursion that's really a fold — `Enum.reduce` is clearer"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_fold_shaped_recursion(file, ast)
    end
  end

  defp find_fold_shaped_recursion(file, ast) do
    ast
    |> private_clauses_by_name_arity()
    |> Enum.flat_map(fn {{name, arity}, clauses} ->
      maybe_flag(name, arity, clauses, file)
    end)
  end

  # Group `defp` clauses by `{name, arity}`. Only `defp` — public recursion
  # is potentially part of the API.
  defp private_clauses_by_name_arity(ast) do
    ast
    |> AST.find_all(&defp_node?/1)
    |> Enum.group_by(&clause_key/1)
  end

  defp defp_node?({:defp, _, [{:when, _, [{name, _, args} | _]} | _]})
       when is_atom(name) and is_list(args),
       do: true

  defp defp_node?({:defp, _, [{name, _, args} | _]})
       when is_atom(name) and is_list(args),
       do: true

  defp defp_node?(_), do: false

  defp clause_key({:defp, _, [{:when, _, [{name, _, args} | _]} | _]}),
    do: {name, length(args)}

  defp clause_key({:defp, _, [{name, _, args} | _]}), do: {name, length(args)}

  # Pair must contain (a) an empty-list clause and (b) a cons-list clause
  # whose RHS recurses with `tail` and modifies the accumulator. Arity ≥ 2
  # (list + accumulator at minimum).
  defp maybe_flag(name, arity, clauses, file) when arity >= 2 do
    has_empty = Enum.any?(clauses, &empty_clause?/1)
    cons_clause = Enum.find(clauses, &cons_recursion?(&1, name, arity))

    case has_empty and not is_nil(cons_clause) do
      true ->
        meta = clause_meta(cons_clause)
        [build_diagnostic(file, AST.line(meta), name, arity)]

      false ->
        []
    end
  end

  defp maybe_flag(_, _, _, _), do: []

  defp clause_meta({:defp, meta, _}), do: meta

  # An empty-list clause: first arg is `[]` and the body is the bare
  # accumulator variable, OR an arbitrary expression on the accumulator
  # (e.g., `Enum.reverse(acc)`).
  defp empty_clause?({:defp, _, [head | _]}) do
    args = head_args(head)

    case args do
      [first | _] -> empty_list_pattern?(first)
      _ -> false
    end
  end

  defp head_args({:when, _, [{_, _, args} | _]}), do: args
  defp head_args({_, _, args}), do: args
  defp head_args(_), do: []

  defp empty_list_pattern?([]), do: true
  defp empty_list_pattern?({:__block__, _, [[]]}), do: true
  defp empty_list_pattern?(_), do: false

  # A cons-list clause: first arg is `[h | t]`, RHS calls the same fn
  # with `t` as first arg.
  defp cons_recursion?({:defp, _, [head, body_kw]}, name, arity) do
    args = head_args(head)

    case args do
      [first | _] ->
        case cons_pattern_tail(first) do
          {:ok, tail_var} -> body_recurses_with_tail?(body_kw, name, arity, tail_var)
          :error -> false
        end

      _ ->
        false
    end
  end

  defp cons_recursion?(_, _, _), do: false

  # `[h | t]` parses to `[{:|, _, [h, t]}]`. With literal_encoder it can be
  # `{:__block__, _, [[{:|, _, [h, t]}]]}`. Return the tail variable name
  # if it matches; `:error` otherwise.
  defp cons_pattern_tail([{:|, _, [_head, {tail, _, ctx}]}]) when is_atom(tail) and is_atom(ctx),
    do: {:ok, tail}

  defp cons_pattern_tail({:__block__, _, [[{:|, _, [_head, {tail, _, ctx}]}]]})
       when is_atom(tail) and is_atom(ctx),
       do: {:ok, tail}

  defp cons_pattern_tail(_), do: :error

  # Walk the body looking for `name(t, ...)` where t is the bound tail.
  defp body_recurses_with_tail?(body_kw, name, arity, tail_var) do
    body = AST.function_body(elem_to_list(body_kw))

    AST.contains?(body, fn
      {^name, _, args} when is_list(args) and length(args) == arity ->
        first_arg_matches_tail?(args, tail_var)

      _ ->
        false
    end)
  end

  defp elem_to_list(kw) when is_list(kw), do: [kw]
  defp elem_to_list(other), do: [other]

  defp first_arg_matches_tail?([{var, _, ctx} | _], tail_var)
       when is_atom(var) and is_atom(ctx),
       do: var == tail_var

  defp first_arg_matches_tail?(_, _), do: false

  defp build_diagnostic(file, line, name, arity) do
    Diagnostic.info("6.100",
      title: "List recursion that's a fold",
      message:
        "#{name}/#{arity} matches `[]` and `[h | t]` and recurses with " <>
          "`t` and an accumulator — that's the shape of `Enum.reduce`.",
      why:
        "A two-clause private function with `[]` -> acc and `[h | t]` -> " <>
          "recurse(t, transform(h, acc)) is the canonical fold. `Enum.reduce/3` " <>
          "expresses the same intent in one line, names what's happening " <>
          "(reduce / fold), and removes the double-clause boilerplate. The " <>
          "accumulator type changes nothing — `reduce` accepts any initial " <>
          "value. For early termination use `reduce_while`. For collecting " <>
          "while transforming use `map_reduce`. For position-aware folds " <>
          "use `Enum.with_index` upstream. The named-function form is only " <>
          "necessary for non-fold shapes (tree traversal, mutual recursion).",
      alternatives: [
        Fix.new(
          summary: "Replace with `Enum.reduce`",
          detail:
            "Move the cons-clause's transform into the reducer lambda; the " <>
              "empty clause becomes the initial accumulator.",
          example: """
          ```elixir
          # before
          defp do_sum([], acc), do: acc
          defp do_sum([h | t], acc), do: do_sum(t, acc + h)

          # after
          Enum.reduce(xs, 0, fn h, acc -> acc + h end)
          # or simply
          Enum.sum(xs)
          ```
          """,
          applies_when: "The recursion is a straight fold — no early termination."
        ),
        Fix.new(
          summary: "Use `Enum.reduce_while` for early termination",
          detail:
            "If the recursion would short-circuit on a sentinel, use " <>
              "`Enum.reduce_while/3` with `{:halt, _}` / `{:cont, _}`.",
          applies_when:
            "The recursion stops on a condition rather than processing the whole list."
        )
      ],
      file: file,
      line: line
    )
  end
end
