defmodule Archdo.Stats.FunctionMetrics do
  @moduledoc """
  Per-function structural metrics — statement count, return-point count,
  local-variable count, parameter count. Pure function over AST. Public
  API consumed by `Archdo.Stats` and surfaced in `mix archdo --metrics`
  as a "complex functions" section.

  Definitions:

  - **statements** — number of top-level expressions in the function
    body (1 for a single-expression body; the length of a `__block__`
    otherwise).
  - **return_points** — distinct exit points at the body's tail
    position. A `case`/`cond` contributes one per clause; `if`/`unless`
    contributes one per non-nil branch (do, else); `with` contributes
    1 for the do-body plus one per `else:` clause; everything else
    counts as a single tail expression. Nested branches count from the
    outermost tail-position structure.
  - **locals** — distinct variable names bound by `=` in the body,
    excluding names already bound in the function head. Pattern matches
    in `case`/`->` clauses are NOT counted as locals — only `=` LHS.
  - **params** — function arity (length of the head's argument list).
  """

  Module.register_attribute(__MODULE__, :archdo_volatility, persist: true)
  @archdo_volatility :stable

  alias Archdo.AST.Unwrap

  @def_kws [:def, :defp, :defmacro, :defmacrop]

  @type metric :: %{
          name: atom(),
          arity: arity(),
          statements: non_neg_integer(),
          return_points: non_neg_integer(),
          locals: non_neg_integer(),
          params: arity()
        }

  @doc """
  Analyze every `def`/`defp`/`defmacro`/`defmacrop` form found anywhere
  in the AST and return a list of per-function metric maps. Order
  follows source order (first def first).
  """
  @spec analyze(Macro.t()) :: [metric()]
  def analyze(ast) do
    ast
    |> collect_functions()
    |> Enum.map(&analyze_function/1)
  end

  defp collect_functions(ast) do
    {_, fns} =
      Macro.prewalk(ast, [], fn
        {def_kw, _, [head, kw]} = node, acc when def_kw in @def_kws and is_list(kw) ->
          case kw_get(kw, :do) do
            {:ok, body} -> {node, [{head, body} | acc]}
            :error -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(fns)
  end

  # §§ elixir-implementing: §2.1 — production ASTs from
  # `AST.parse_files` use `literal_encoder` which wraps keyword keys
  # in `{:__block__, _, [atom]}`. This helper unwraps either shape so
  # walkers work uniformly on both AST sources.
  defp kw_get([], _), do: :error

  defp kw_get([{key, val} | rest], target) do
    case Unwrap.try_atom(key) do
      ^target -> {:ok, val}
      _ -> kw_get(rest, target)
    end
  end

  defp kw_get([_ | rest], target), do: kw_get(rest, target)

  defp kw_has?(kw, key), do: match?({:ok, _}, kw_get(kw, key))

  defp analyze_function({head, body}) do
    {name, args} = head_info(head)
    arity = length(args)
    head_var_set = MapSet.new(Enum.flat_map(args, &extract_pattern_vars/1))

    %{
      name: name,
      arity: arity,
      statements: count_statements(body),
      return_points: count_return_points(body),
      locals: count_locals(body, head_var_set),
      params: arity
    }
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatches on the
  # arity-0 (`{name, _, nil}`) vs arity-N (`{name, _, list}`) shapes.
  defp head_info({name, _, nil}) when is_atom(name), do: {name, []}

  defp head_info({name, _, args}) when is_atom(name) and is_list(args),
    do: {name, args}

  # `def f(x) when guard, do: ...` — head wraps a `:when` AST node.
  defp head_info({:when, _, [inner_head, _guard]}), do: head_info(inner_head)

  # --- Statements ---

  defp count_statements({:__block__, _, exprs}) when is_list(exprs), do: length(exprs)
  defp count_statements(_), do: 1

  # --- Return points ---

  # `case` / `cond` — one return per clause. The keyword key may be
  # either bare `:do` (string_to_quoted) or `{:__block__, _, [:do]}`
  # (parse_files with literal_encoder); kw_get handles both.
  defp count_return_points({:case, _, [_arg, kw]}) when is_list(kw),
    do: clause_count(kw_get(kw, :do))

  defp count_return_points({:cond, _, [kw]}) when is_list(kw),
    do: clause_count(kw_get(kw, :do))

  # RULE-EXCEPTION: Credo.Check.Refactor.UnlessWithElse — this clause
  # pattern-matches on `:if` / `:unless` AST atoms in USER code; it
  # does not itself use `unless ... else`.
  defp count_return_points({op, _, args}) when op in [:if, :unless] do
    case List.last(args) do
      kw when is_list(kw) -> branch_count(kw)
      _ -> 1
    end
  end

  # `with` — 1 for do-body + one per else clause.
  defp count_return_points({:with, _, args}) do
    case List.last(args) do
      kw when is_list(kw) -> with_branch_count(kw)
      _ -> 1
    end
  end

  # `__block__` may be either a wrapped literal (single child, no
  # do-block) or a real block (the LAST expression is in tail position).
  defp count_return_points({:__block__, _, [single]}), do: count_return_points(single)

  defp count_return_points({:__block__, _, exprs}) when is_list(exprs) do
    case List.last(exprs) do
      nil -> 1
      last -> count_return_points(last)
    end
  end

  defp count_return_points(_), do: 1

  defp clause_count({:ok, clauses}) when is_list(clauses), do: length(clauses)
  defp clause_count(_), do: 1

  defp branch_count(kw) do
    do_count = bool_to_int(kw_has?(kw, :do))
    else_count = bool_to_int(kw_has?(kw, :else))
    max(1, do_count + else_count)
  end

  defp with_branch_count(kw) do
    do_count = bool_to_int(kw_has?(kw, :do))

    else_count =
      case kw_get(kw, :else) do
        {:ok, clauses} when is_list(clauses) -> length(clauses)
        {:ok, _} -> 1
        :error -> 0
      end

    do_count + else_count
  end

  defp bool_to_int(true), do: 1
  defp bool_to_int(false), do: 0

  # --- Locals ---
  #
  # Walk the body collecting names from `=` LHS patterns. Subtract
  # head-bound names. Distinct count.

  defp count_locals(body, head_var_set) do
    body
    |> collect_assignment_vars()
    |> Enum.reject(&MapSet.member?(head_var_set, &1))
    |> Enum.uniq()
    |> length()
  end

  defp collect_assignment_vars(ast) do
    {_, names} =
      Macro.prewalk(ast, [], fn
        {:=, _, [lhs, _rhs]} = node, acc ->
          {node, extract_pattern_vars(lhs) ++ acc}

        node, acc ->
          {node, acc}
      end)

    names
  end

  # --- Pattern variable extraction ---
  #
  # Returns a list of atom names bound by the given pattern AST.
  # Wildcards (`_`, `_x`) and pin operators do not bind new names.
  # Implemented as a tail-recursive worklist over a stack of nodes —
  # avoids `++` in tail position and the broken-TCO false positive on
  # body-recursive concatenation.

  defp extract_pattern_vars(pat), do: do_extract([pat], [])

  defp do_extract([], acc), do: Enum.reverse(acc)

  defp do_extract([{name, _, ctx} | rest], acc)
       when is_atom(name) and is_atom(ctx) do
    do_extract(rest, maybe_collect(name, acc))
  end

  defp do_extract([{:=, _, [lhs, rhs]} | rest], acc),
    do: do_extract([lhs, rhs | rest], acc)

  defp do_extract([{:^, _, _} | rest], acc), do: do_extract(rest, acc)

  defp do_extract([{:%, _, [_alias, {:%{}, _, fields}]} | rest], acc),
    do: do_extract(field_values(fields) ++ rest, acc)

  defp do_extract([{:%{}, _, fields} | rest], acc),
    do: do_extract(field_values(fields) ++ rest, acc)

  defp do_extract([{:{}, _, elems} | rest], acc),
    do: do_extract(elems ++ rest, acc)

  defp do_extract([{:|, _, [h, t]} | rest], acc),
    do: do_extract([h, t | rest], acc)

  defp do_extract([{:<<>>, _, parts} | rest], acc),
    do: do_extract(parts ++ rest, acc)

  defp do_extract([{:"::", _, [pat, _type]} | rest], acc),
    do: do_extract([pat | rest], acc)

  defp do_extract([{a, b} | rest], acc),
    do: do_extract([a, b | rest], acc)

  defp do_extract([list | rest], acc) when is_list(list),
    do: do_extract(list ++ rest, acc)

  defp do_extract([_other | rest], acc), do: do_extract(rest, acc)

  defp maybe_collect(name, acc) do
    case String.starts_with?(Atom.to_string(name), "_") do
      true -> acc
      false -> [name | acc]
    end
  end

  defp field_values(fields), do: Enum.map(fields, fn {_k, v} -> v end)
end
