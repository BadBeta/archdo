defmodule Archdo.Rules.Module.ParseInEnumLambda do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.90"

  @impl true
  def description,
    do:
      "Per-iteration `Decimal.new` / `Date.from_iso8601!` / `DateTime.from_iso8601!` " <>
        "/ `NaiveDateTime.from_iso8601!` inside an `Enum.*` / `Stream.*` lambda — " <>
        "construct once outside the loop"

  # Module + function pairs whose call inside an Enum/Stream lambda is
  # a parsing or value-construction operation worth hoisting.
  @parse_calls [
    {[:Decimal], :new},
    {[:Date], :from_iso8601!},
    {[:DateTime], :from_iso8601!},
    {[:NaiveDateTime], :from_iso8601!},
    {[:Time], :from_iso8601!},
    {[:Regex], :compile!}
  ]

  @enum_funs [
    :map,
    :filter,
    :reject,
    :reduce,
    :each,
    :flat_map,
    :map_join,
    :find,
    :any?,
    :all?,
    :group_by,
    :sort_by,
    :uniq_by,
    :split_with,
    :take_while,
    :drop_while,
    :count
  ]

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    ast
    |> AST.find_all(&enum_call_with_lambda?/1)
    |> Enum.flat_map(&loop_invariant_parse_metas/1)
    |> Enum.map(fn meta -> build_diagnostic(file, AST.line(meta)) end)
  end

  defp enum_call_with_lambda?({{:., _, [{:__aliases__, _, [container]}, fun]}, _, args})
       when container in [:Enum, :Stream] and fun in @enum_funs and is_list(args) do
    Enum.any?(args, &lambda?/1)
  end

  defp enum_call_with_lambda?(_), do: false

  defp lambda?({:fn, _, _}), do: true
  defp lambda?(_), do: false

  # Extract loop-invariant parse-call metas from the lambda inside this Enum.*
  # call. A parse call is loop-INVARIANT (worth hoisting) when none of its
  # arguments reference a variable bound by the lambda parameter. Loop-VARIANT
  # parse calls (e.g. `Date.from_iso8601!(invoice["payout_date"])` where
  # `invoice` is the lambda param) cannot be hoisted and are skipped.
  defp loop_invariant_parse_metas({{:., _, [{:__aliases__, _, _}, _]}, _, args}) do
    Enum.flat_map(args, fn
      {:fn, _, clauses} -> Enum.flat_map(clauses, &invariant_metas_in_clause/1)
      _ -> []
    end)
  end

  defp loop_invariant_parse_metas(_), do: []

  defp invariant_metas_in_clause({:->, _, [params, body]}) do
    param_names = collect_param_vars(params)
    walk_for_invariant(body, param_names, [])
  end

  defp invariant_metas_in_clause(_), do: []

  # Stop at nested lambdas — those get their own per-Enum.* analysis pass.
  defp walk_for_invariant({:fn, _, _}, _param_names, acc), do: acc

  # Pipe form: `lhs |> Mod.fun(rhs_args)` — effective parse input is `[lhs | rhs_args]`.
  # Recognize this case explicitly so direct walk doesn't double-count rhs.
  defp walk_for_invariant({:|>, _, [lhs, rhs]}, param_names, acc) do
    case classify_pipe_rhs(rhs, lhs, param_names) do
      {:invariant_parse, meta} ->
        acc = [meta | acc]
        acc = walk_for_invariant(lhs, param_names, acc)
        walk_for_invariant_args(call_args(rhs), param_names, acc)

      :variant_parse ->
        # rhs is a parse call but loop-variant; don't recurse into rhs as a
        # direct call (would re-flag with empty args). Walk children only.
        acc = walk_for_invariant(lhs, param_names, acc)
        walk_for_invariant_args(call_args(rhs), param_names, acc)

      :not_parse ->
        acc = walk_for_invariant(lhs, param_names, acc)
        walk_for_invariant(rhs, param_names, acc)
    end
  end

  # Direct call form: `Mod.fun(args)`. If it's a parse call and args don't
  # reference any lambda param, flag it.
  defp walk_for_invariant(
         {{:., _, [{:__aliases__, _, parts}, fun]}, meta, args},
         param_names,
         acc
       )
       when is_list(args) do
    acc =
      case parse_call?(parts, fun) and not Enum.any?(args, &references_var?(&1, param_names)) do
        true -> [meta | acc]
        false -> acc
      end

    walk_for_invariant_args(args, param_names, acc)
  end

  defp walk_for_invariant({_, _, args}, param_names, acc) when is_list(args) do
    walk_for_invariant_args(args, param_names, acc)
  end

  defp walk_for_invariant(list, param_names, acc) when is_list(list) do
    walk_for_invariant_args(list, param_names, acc)
  end

  defp walk_for_invariant({a, b}, param_names, acc) do
    acc = walk_for_invariant(a, param_names, acc)
    walk_for_invariant(b, param_names, acc)
  end

  defp walk_for_invariant(_, _, acc), do: acc

  defp walk_for_invariant_args(args, param_names, acc) when is_list(args) do
    Enum.reduce(args, acc, fn arg, a -> walk_for_invariant(arg, param_names, a) end)
  end

  defp classify_pipe_rhs(
         {{:., _, [{:__aliases__, _, parts}, fun]}, meta, rhs_args},
         lhs,
         param_names
       )
       when is_list(rhs_args) do
    case parse_call?(parts, fun) do
      true ->
        case Enum.any?([lhs | rhs_args], &references_var?(&1, param_names)) do
          true -> :variant_parse
          false -> {:invariant_parse, meta}
        end

      false ->
        :not_parse
    end
  end

  defp classify_pipe_rhs(_, _, _), do: :not_parse

  defp call_args({_, _, args}) when is_list(args), do: args
  defp call_args(_), do: []

  defp parse_call?(parts, fun), do: {parts, fun} in @parse_calls

  # Extract atom var names from lambda parameter patterns. Walks the patterns
  # collecting any bare variable AST `{name, meta, ctx}` where ctx is nil or
  # an atom (variable hygiene) and name is not `_`.
  defp collect_param_vars(params) when is_list(params) do
    params |> Enum.flat_map(&extract_vars/1) |> MapSet.new()
  end

  defp references_var?(_ast, %MapSet{} = param_names) when map_size(param_names.map) == 0 do
    false
  end

  defp references_var?(ast, param_names) do
    Enum.any?(extract_vars(ast), &MapSet.member?(param_names, &1))
  end

  defp extract_vars(ast) do
    {_, vars} =
      Macro.prewalk(ast, [], fn
        {var, _meta, ctx} = node, acc
        when is_atom(var) and (is_atom(ctx) or is_nil(ctx)) and var != :_ ->
          {node, [var | acc]}

        node, acc ->
          {node, acc}
      end)

    vars
  end

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.90",
      title: "Parse / construct inside `Enum.*` lambda — hoist out of the loop",
      message:
        "An `Enum.*` lambda calls `Decimal.new` / `Date.from_iso8601!` / similar on " <>
          "every iteration. These calls allocate and (for ISO8601 parses) tokenize / " <>
          "validate the input string each time — wasted work if the value is the " <>
          "same across iterations.",
      why:
        "When the parsed value does not depend on the lambda's argument, the work " <>
          "is per-element but the result is constant. For an N-row dataset that's N " <>
          "redundant allocations and N redundant parses. With Decimal in particular, " <>
          "constructing the same factor (`Decimal.new(\"1.20\")`) per row is a real " <>
          "hot-path cost in financial code.",
      alternatives: [
        Fix.new(
          summary: "Construct once, then reference inside the lambda",
          detail:
            "rate = Decimal.new(\"1.20\")\n\n" <>
              "items\n" <>
              "|> Enum.map(fn item -> Decimal.mult(item.amount, rate) end)\n\n" <>
              "# Or via let-binding inside a `with`:\n" <>
              "with cutoff <- Date.from_iso8601!(cutoff_str) do\n" <>
              "  Enum.filter(rows, &(Date.compare(&1.date, cutoff) == :gt))\nend",
          applies_when:
            "When the constructed value does not depend on the per-element variable. If it does, this rule does not apply."
        )
      ],
      references: [
        "elixir-reviewing/performance-catalog.md",
        "elixir-implementing/SKILL.md#2.2"
      ],
      context: %{},
      file: file,
      line: line
    )
  end
end
