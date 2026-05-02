defmodule Archdo.CognitiveComplexity do
  @moduledoc false

  # §§ elixir-planning: §6 — Cognitive complexity engine (Campbell,
  # SonarSource 2018). Distinct from McCabe cyclomatic: tracks human
  # reading difficulty rather than graph paths.
  #
  # Rules (per body):
  #   * +1 per control-flow structure (if, unless, case, cond, with,
  #     try)
  #   * +nesting_depth per nested control-flow structure
  #   * +1 per logical operator (&&, ||, and, or) chained beyond the
  #     first
  #
  # Multi-clause function dispatch is intentionally NOT penalized at
  # the per-body level — score/1 evaluates one body at a time, and the
  # rule callers (CE-23, CE-24) decide whether to roll up across
  # clauses or keep them independent. This is the key Elixir-specific
  # calibration that prevents over-firing on idiomatic dispatch.

  @control_flow ~w(if unless case cond with try)a
  @logical_ops ~w(&& || and or)a

  @doc """
  Compute cognitive complexity for a function body AST.
  Returns a non-negative integer; 0 for trivial bodies.
  """
  @spec score(Macro.t() | nil) :: non_neg_integer()
  def score(nil), do: 0

  def score(body) do
    {_, {total, _depth, _logical_seen}} =
      walk(body, {0, 0, MapSet.new()})

    total
  end

  defp walk({op, _, _} = node, {total, depth, logical}) when op in @control_flow do
    increment = 1 + depth
    new_total = total + increment

    children = children(node)

    {child_total, _, child_logical} =
      Enum.reduce(children, {new_total, depth + 1, logical}, fn child, acc ->
        {_, new_acc} = walk(child, acc)
        new_acc
      end)

    {node, {child_total, depth, child_logical}}
  end

  defp walk({op, _meta, _args} = node, {total, depth, logical}) when op in @logical_ops do
    # Score every logical operator occurrence; chained `a && b && c`
    # parses as nested binary nodes, naturally producing 2 hits.
    new_logical = MapSet.put(logical, :seen)

    children = children(node)

    {child_total, _, child_logical} =
      Enum.reduce(children, {total + 1, depth, new_logical}, fn child, acc ->
        {_, new_acc} = walk(child, acc)
        new_acc
      end)

    {node, {child_total, depth, child_logical}}
  end

  defp walk({_, _, args} = node, acc) when is_list(args) do
    {child_total, child_depth, child_logical} =
      Enum.reduce(args, acc, fn child, inner_acc ->
        {_, new_acc} = walk(child, inner_acc)
        new_acc
      end)

    {node, {child_total, child_depth, child_logical}}
  end

  defp walk(list, acc) when is_list(list) do
    final =
      Enum.reduce(list, acc, fn child, inner_acc ->
        {_, new_acc} = walk(child, inner_acc)
        new_acc
      end)

    {list, final}
  end

  defp walk({left, right}, acc) do
    {_, acc1} = walk(left, acc)
    {_, acc2} = walk(right, acc1)
    {{left, right}, acc2}
  end

  defp walk(other, acc), do: {other, acc}

  defp children({_op, _, args}) when is_list(args), do: args
  defp children(_), do: []
end
