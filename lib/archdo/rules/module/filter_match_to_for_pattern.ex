defmodule Archdo.Rules.Module.FilterMatchToForPattern do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.74"

  @impl true
  def description,
    do:
      "`Enum.filter(coll, &match?(p, &1)) |> Enum.map(fn p -> body end)` — " <>
        "use `for p <- coll, do: body`"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    Enum.map(AST.find_all(ast, &filter_match_then_map?/1), fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta))
    end)
  end

  # `... |> Enum.filter(&match?(_, &1)) |> Enum.map(fn _ -> _ end)`
  defp filter_match_then_map?({:|>, _, [lhs, rhs]}) do
    ends_in_filter_match?(lhs) and enum_map_call?(rhs)
  end

  defp filter_match_then_map?(_), do: false

  defp ends_in_filter_match?({:|>, _, [_, rhs]}), do: filter_match_call?(rhs)
  defp ends_in_filter_match?(node), do: filter_match_call?(node)

  # Enum.filter where the predicate is a `&match?(p, &1)` capture.
  # In pipeline form (`coll |> Enum.filter(pred)`) args is `[pred]`;
  # in direct form (`Enum.filter(coll, pred)`) args is `[coll, pred]`.
  defp filter_match_call?({{:., _, [{:__aliases__, _, [:Enum]}, :filter]}, _, args})
       when is_list(args) do
    case List.last(args) do
      nil -> false
      pred -> match_capture?(pred)
    end
  end

  defp filter_match_call?(_), do: false

  defp match_capture?({:&, _, [{:match?, _, [_pattern, {:&, _, [1]}]}]}), do: true
  defp match_capture?(_), do: false

  defp enum_map_call?({{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, _}), do: true
  defp enum_map_call?(_), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.74",
      title: "filter-match + map — use a `for` comprehension with pattern",
      message:
        "`Enum.filter(coll, &match?(p, &1)) |> Enum.map(fn p -> body end)` filters then " <>
          "destructures in a separate pass. A `for` comprehension with the pattern in the " <>
          "generator does both in one step.",
      why:
        "`for pattern <- coll, do: body` silently skips elements that don't match the " <>
          "pattern, then destructures matching ones in the body. Single pass, no " <>
          "intermediate list, no duplicate `match?` + destructure pair to keep in sync.",
      alternatives: [
        Fix.new(
          summary: "Replace with a `for` comprehension",
          detail: "for {:ok, v} <- results, do: v",
          applies_when: "When the filter pattern is the same as the map's destructure pattern."
        )
      ],
      references: ["elixir-implementing/SKILL.md#5.4", "elixir-implementing/SKILL.md#2.2"],
      context: %{},
      file: file,
      line: line
    )
  end
end
