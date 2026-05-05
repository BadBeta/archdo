defmodule Archdo.Rules.Module.SplitWithOpportunity do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.67"

  @impl true
  def description,
    do: "{Enum.filter(coll, pred), Enum.reject(coll, pred)} — use Enum.split_with/2"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    Enum.map(AST.find_all(ast, &filter_reject_tuple?/1), &build_diagnostic(file, line_of(&1)))
  end

  # 2-tuple `{a, b}` doesn't carry its own metadata; pull the line
  # from one of its elements. `Enum.filter` (or `Enum.reject`) is one
  # of the elements, so we can use that node's line.
  defp line_of({{{:., _, _}, meta, _}, _}), do: AST.line(meta)
  defp line_of({_, {{:., _, _}, meta, _}}), do: AST.line(meta)
  defp line_of(_), do: 1

  # 2-tuple `{Enum.filter(c, p), Enum.reject(c, p)}` where the
  # collection AND predicate match between the two calls.
  defp filter_reject_tuple?({a, b}) do
    matching_filter_reject?(a, b) or matching_filter_reject?(b, a)
  end

  defp filter_reject_tuple?(_), do: false

  defp matching_filter_reject?(
         {{:., _, [{:__aliases__, _, [:Enum]}, :filter]}, _, [c1, p1]},
         {{:., _, [{:__aliases__, _, [:Enum]}, :reject]}, _, [c2, p2]}
       ) do
    same_arg?(c1, c2) and same_arg?(p1, p2)
  end

  defp matching_filter_reject?(_, _), do: false

  # Conservative same-arg check: AST equality after stripping metadata.
  defp same_arg?(a, b), do: strip(a) == strip(b)

  defp strip(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.67",
      title: "filter/reject pair — use Enum.split_with/2",
      message:
        "{Enum.filter(coll, pred), Enum.reject(coll, pred)} traverses the collection " <>
          "twice. Enum.split_with/2 does the same in one pass and returns the same shape.",
      why:
        "`Enum.split_with/2` returns `{kept, dropped}` from a single pass — same return " <>
          "shape as the filter/reject tuple, half the iteration cost.",
      alternatives: [
        Fix.new(
          summary: "Replace with Enum.split_with/2",
          detail: "{kept, dropped} = Enum.split_with(users, & &1.active)",
          applies_when: "When filter and reject use the same collection AND the same predicate."
        )
      ],
      references: ["elixir-implementing/SKILL.md#2.2"],
      context: %{},
      file: file,
      line: line
    )
  end
end
