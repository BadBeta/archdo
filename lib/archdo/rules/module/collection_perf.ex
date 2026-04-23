defmodule Archdo.Rules.Module.CollectionPerf do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Rules.Helpers.LoopDetection

  @impl true
  def id, do: "6.51"

  @impl true
  def description, do: "Collection operation has a more efficient alternative"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_wasteful_ops(file, ast)
    end
  end

  defp find_wasteful_ops(file, ast) do
    List.flatten([
      find_count_gt_zero(file, ast),
      find_filter_then_map(file, ast),
      find_sort_then_first(file, ast),
      find_double_reverse(file, ast),
      find_member_in_loop(file, ast)
    ])
  end

  # --- Enum.count(list, fun) > 0 → Enum.any?(list, fun) ---

  defp find_count_gt_zero(file, ast) do
    Enum.map(AST.find_all(ast, fn
      # Enum.count(x, fun) > 0
      {:>, _, [
        {{:., _, [{:__aliases__, _, [:Enum]}, :count]}, _, [_, _]},
        val
      ]} ->
        zero_literal?(val)

      # Enum.count(x, fun) != 0
      {:!=, _, [
        {{:., _, [{:__aliases__, _, [:Enum]}, :count]}, _, [_, _]},
        val
      ]} ->
        zero_literal?(val)

      # Enum.count(x, fun) == 0  (inverse — should be !Enum.any?)
      {:==, _, [
        {{:., _, [{:__aliases__, _, [:Enum]}, :count]}, _, [_, _]},
        val
      ]} ->
        zero_literal?(val)

      _ ->
        false
    end), fn {op, meta, _} ->
      replacement =
        case op do
          :== -> "not Enum.any?(collection, fun)"
          _ -> "Enum.any?(collection, fun)"
        end

      build_diagnostic(file, AST.line(meta), :count_vs_any, replacement)
    end)
  end

  defp zero_literal?(0), do: true
  defp zero_literal?({:__block__, _, [0]}), do: true
  defp zero_literal?(_), do: false

  # --- Enum.filter |> Enum.map → for comprehension ---

  defp find_filter_then_map(file, ast) do
    Enum.map(AST.find_all(ast, fn
      # x |> Enum.filter(...) |> Enum.map(...)  — outer pipe
      {:|>, _, [
        {:|>, _, [_, {{:., _, [{:__aliases__, _, [:Enum]}, filter_fn]}, _, _}]},
        {{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, _}
      ]} when filter_fn in [:filter, :reject] ->
        true

      # Enum.map(Enum.filter(list, f), g) — nested call form
      {{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, [
        {{:., _, [{:__aliases__, _, [:Enum]}, filter_fn]}, _, _} | _
      ]} when filter_fn in [:filter, :reject] ->
        true

      _ ->
        false
    end), fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta), :filter_then_map, nil)
    end)
  end

  # --- Enum.sort |> hd / Enum.sort |> Enum.take(1) → Enum.min ---

  defp find_sort_then_first(file, ast) do
    Enum.map(AST.find_all(ast, fn
      # x |> Enum.sort() |> hd()  — 3-step pipe
      {:|>, _, [
        {:|>, _, [_, {{:., _, [{:__aliases__, _, [:Enum]}, sort_fn]}, _, _}]},
        {:hd, _, _}
      ]} when sort_fn in [:sort, :sort_by] ->
        true

      # Enum.sort(list) |> hd()  — 2-step pipe
      {:|>, _, [
        {{:., _, [{:__aliases__, _, [:Enum]}, sort_fn]}, _, _},
        {:hd, _, _}
      ]} when sort_fn in [:sort, :sort_by] ->
        true

      # hd(Enum.sort(list))
      {:hd, _, [{{:., _, [{:__aliases__, _, [:Enum]}, sort_fn]}, _, _}]}
      when sort_fn in [:sort, :sort_by] ->
        true

      # x |> Enum.sort() |> Enum.take(1)  — 3-step pipe
      {:|>, _, [
        {:|>, _, [_, {{:., _, [{:__aliases__, _, [:Enum]}, sort_fn]}, _, _}]},
        {{:., _, [{:__aliases__, _, [:Enum]}, :take]}, _, [val]}
      ]} when sort_fn in [:sort, :sort_by] ->
        one_literal?(val)

      _ ->
        false
    end), fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta), :sort_then_first, nil)
    end)
  end

  defp one_literal?(1), do: true
  defp one_literal?({:__block__, _, [1]}), do: true
  defp one_literal?(_), do: false

  # --- Enum.reverse(Enum.reverse(list)) — identity ---

  defp find_double_reverse(file, ast) do
    Enum.map(AST.find_all(ast, fn
      # Enum.reverse(Enum.reverse(x))
      {{:., _, [{:__aliases__, _, [:Enum]}, :reverse]}, _, [
        {{:., _, [{:__aliases__, _, [:Enum]}, :reverse]}, _, _}
      ]} ->
        true

      # x |> Enum.reverse() |> Enum.reverse()
      {:|>, _, [
        {:|>, _, [
          _,
          {{:., _, [{:__aliases__, _, [:Enum]}, :reverse]}, _, _}
        ]},
        {{:., _, [{:__aliases__, _, [:Enum]}, :reverse]}, _, _}
      ]} ->
        true

      _ ->
        false
    end), fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta), :double_reverse, nil)
    end)
  end

  # --- Enum.member? on list inside a loop ---

  defp find_member_in_loop(file, ast) do
    member_predicate = fn
      {{:., _, [{:__aliases__, _, [:Enum]}, :member?]}, _, _} -> true
      _ -> false
    end

    LoopDetection.find_in_all_loops(ast, member_predicate)
    |> Enum.map(fn {_, meta} ->
      build_diagnostic(file, AST.line(meta), :member_in_loop, nil)
    end)
  end

  # --- Diagnostics ---

  defp build_diagnostic(file, line, :count_vs_any, replacement) do
    Diagnostic.info("6.51",
      title: "Enum.count for boolean check",
      message: "Enum.count(list, fun) compared to 0 — use #{replacement} to short-circuit",
      why:
        "Enum.count traverses the entire collection counting all matches. " <>
          "Enum.any?/2 stops at the first match. For a 10,000-element list " <>
          "where the first element matches, any? is ~10,000x faster.",
      alternatives: [
        Fix.new(
          summary: "Use Enum.any?/2 or Enum.all?/2",
          detail: "`Enum.count(list, fun) > 0` -> `Enum.any?(list, fun)`\n" <>
            "`Enum.count(list, fun) == 0` -> `not Enum.any?(list, fun)`",
          applies_when: "You only need to know if any/no elements match."
        )
      ],
      tags: [:perf],
      file: file,
      line: line
    )
  end

  defp build_diagnostic(file, line, :filter_then_map, _) do
    Diagnostic.info("6.51",
      title: "Enum.filter |> Enum.map — two passes",
      message: "Piping filter into map traverses the collection twice — use a for comprehension",
      why:
        "Enum.filter builds an intermediate list, then Enum.map traverses it again. " <>
          "A for comprehension with a guard does both in a single pass with no " <>
          "intermediate allocation.",
      alternatives: [
        Fix.new(
          summary: "Use a for comprehension",
          detail: "`list |> Enum.filter(&pred/1) |> Enum.map(&transform/1)` ->\n" <>
            "`for item <- list, pred(item), do: transform(item)`",
          applies_when: "The filter and map are independent operations on the same collection."
        ),
        Fix.new(
          summary: "Use Enum.flat_map",
          detail: "`Enum.flat_map(list, fn x -> if pred(x), do: [transform(x)], else: [] end)`",
          applies_when: "The predicate and transform are tightly coupled."
        )
      ],
      tags: [:perf],
      file: file,
      line: line
    )
  end

  defp build_diagnostic(file, line, :sort_then_first, _) do
    Diagnostic.info("6.51",
      title: "Enum.sort to get first element",
      message: "Sorting entire collection to get min/max — use Enum.min/1 or Enum.max/1",
      why:
        "Enum.sort is O(n log n). Enum.min/1 and Enum.max/1 are O(n). " <>
          "For Enum.sort_by(list, fun) |> hd(), use Enum.min_by(list, fun).",
      alternatives: [
        Fix.new(
          summary: "Use Enum.min/max or Enum.min_by/max_by",
          detail: "`Enum.sort(list) |> hd()` -> `Enum.min(list)`\n" <>
            "`Enum.sort_by(list, &fun/1) |> hd()` -> `Enum.min_by(list, &fun/1)`",
          applies_when: "You only need the smallest or largest element."
        )
      ],
      tags: [:perf],
      file: file,
      line: line
    )
  end

  defp build_diagnostic(file, line, :double_reverse, _) do
    Diagnostic.info("6.51",
      title: "Double Enum.reverse — identity operation",
      message: "Enum.reverse(Enum.reverse(list)) returns the original list — remove both calls",
      why:
        "Two consecutive reverses cancel out, wasting 2*O(n) operations. " <>
          "This usually indicates a refactoring leftover where one reverse was " <>
          "added to fix ordering after another reverse was already present.",
      alternatives: [
        Fix.new(
          summary: "Remove both reverse calls",
          detail: "The list is already in the correct order — the reverses cancel out.",
          applies_when: "Always."
        )
      ],
      tags: [:perf],
      file: file,
      line: line
    )
  end

  defp build_diagnostic(file, line, :member_in_loop, _) do
    Diagnostic.warning("6.51",
      title: "Enum.member? on list inside loop",
      message: "Enum.member?/2 is O(n) per call — build a MapSet before the loop for O(1) lookups",
      why:
        "Enum.member? does a linear scan of the list for every call. Inside a loop " <>
          "of m iterations over a list of n elements, this is O(m*n). " <>
          "Converting to MapSet once (O(n)) then using MapSet.member? (O(1)) " <>
          "makes the total O(m + n).",
      alternatives: [
        Fix.new(
          summary: "Build a MapSet before the loop",
          detail: "`set = MapSet.new(list)` before the loop,\n" <>
            "then `MapSet.member?(set, item)` inside the loop.",
          applies_when: "The list being checked doesn't change during the loop."
        )
      ],
      tags: [:perf],
      file: file,
      line: line
    )
  end
end
