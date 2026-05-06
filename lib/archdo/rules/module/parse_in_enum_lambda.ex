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
    |> Enum.flat_map(&parse_calls_in_lambda/1)
    |> Enum.map(fn meta -> build_diagnostic(file, AST.line(meta)) end)
  end

  defp enum_call_with_lambda?(
         {{:., _, [{:__aliases__, _, [container]}, fun]}, _, args}
       )
       when container in [:Enum, :Stream] and fun in @enum_funs and is_list(args) do
    Enum.any?(args, &lambda?/1)
  end

  defp enum_call_with_lambda?(_), do: false

  defp lambda?({:fn, _, _}), do: true
  defp lambda?(_), do: false

  defp parse_calls_in_lambda(
         {{:., _, [{:__aliases__, _, _}, _]}, _, args}
       ) do
    Enum.flat_map(args, fn
      {:fn, _, clauses} -> find_parse_calls_in_clauses(clauses)
      _ -> []
    end)
  end

  defp parse_calls_in_lambda(_), do: []

  defp find_parse_calls_in_clauses(clauses) do
    AST.find_all(clauses, &parse_call?/1)
    |> Enum.map(fn {_, meta, _} -> meta end)
  end

  defp parse_call?({{:., _, [{:__aliases__, _, parts}, fun]}, _, _}) do
    {parts, fun} in @parse_calls
  end

  defp parse_call?(_), do: false

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
