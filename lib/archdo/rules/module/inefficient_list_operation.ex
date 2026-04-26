defmodule Archdo.Rules.Module.InefficientListOperation do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Rules.Helpers.LoopDetection

  @impl true
  def id, do: "6.50"

  @impl true
  def description, do: "Inefficient list operation — ignores linked-list O(n) characteristics"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_inefficient_ops(ast, file)
    end
  end

  defp find_inefficient_ops(ast, file) do
    List.flatten([
      find_append_via_concat(ast, file),
      find_concat_accumulator_in_reduce(ast, file),
      find_enum_at_zero(ast, file),
      find_list_last_in_loop(ast, file),
      find_reverse_then_hd(ast, file),
      find_insert_at_neg1(ast, file),
      find_delete_at_in_loop(ast, file),
      find_enum_at_variable_in_loop(ast, file)
    ])
  end

  # --- Pattern 1: list ++ [item] — always flag ---

  defp find_append_via_concat(ast, file) do
    Enum.map(
      AST.find_all(ast, fn
        {:++, _, [_list, [_single_item]]} -> true
        {:++, _, [_list, [{:__block__, _, [_single_item]}]]} -> true
        _ -> false
      end),
      fn {:++, meta, _} ->
        build_diagnostic(file, AST.line(meta), :append_via_concat)
      end
    )
  end

  # --- Pattern 1b: acc ++ list in Enum.reduce — always O(n^2) ---
  # Only checks reduce/reduce_while — in map/flat_map/filter, ++ joins
  # local variables without a growing accumulator, which is fine.

  @reduce_fns [:reduce, :reduce_while]

  defp find_concat_accumulator_in_reduce(ast, file) do
    find_in_reduce_only(ast, file, :concat_accumulator, fn
      {:++, _, [{name, _, ctx}, _right]} when is_atom(name) and is_atom(ctx) -> true
      _ -> false
    end)
  end

  defp find_in_reduce_only(ast, file, kind, predicate) do
    {_, diagnostics} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, mod}, func]}, _meta, args} = node, acc
        when func in @reduce_fns and mod in [[:Enum], [:Stream]] and is_list(args) ->
          new_diags =
            args
            |> Enum.filter(fn
              {:fn, _, _} -> true
              {:&, _, _} -> true
              _ -> false
            end)
            |> Enum.flat_map(fn callback ->
              Enum.map(AST.find_all(callback, predicate), fn {_, meta, _} ->
                build_diagnostic(file, AST.line(meta), kind)
              end)
            end)

          {node, new_diags ++ acc}

        # :lists.foldl/foldr are reduce equivalents
        {{:., _, [:lists, fold_fn]}, _meta, args} = node, acc
        when fold_fn in [:foldl, :foldr] and is_list(args) ->
          new_diags =
            args
            |> Enum.filter(fn
              {:fn, _, _} -> true
              {:&, _, _} -> true
              _ -> false
            end)
            |> Enum.flat_map(fn callback ->
              Enum.map(AST.find_all(callback, predicate), fn {_, meta, _} ->
                build_diagnostic(file, AST.line(meta), kind)
              end)
            end)

          {node, new_diags ++ acc}

        {:for, _meta, args} = node, acc when is_list(args) ->
          case has_reduce_option?(args) do
            true ->
              do_block =
                Enum.find_value(args, fn
                  [do: body] -> body
                  {:do, body} -> body
                  _ -> nil
                end)

              new_diags =
                case do_block do
                  nil ->
                    []

                  body ->
                    Enum.map(AST.find_all(body, predicate), fn {_, meta, _} ->
                      build_diagnostic(file, AST.line(meta), kind)
                    end)
                end

              {node, new_diags ++ acc}

            false ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    diagnostics
  end

  defp has_reduce_option?(args) do
    Enum.any?(args, fn
      {:reduce, _} -> true
      {{:__block__, _, [:reduce]}, _} -> true
      _ -> false
    end)
  end

  # --- Pattern 2: Enum.at(list, 0) — always flag ---

  defp find_enum_at_zero(ast, file) do
    Enum.map(
      AST.find_all(ast, fn
        {{:., _, [{:__aliases__, _, [:Enum]}, :at]}, _, [_, 0]} -> true
        {{:., _, [{:__aliases__, _, [:Enum]}, :at]}, _, [_, {:__block__, _, [0]}]} -> true
        _ -> false
      end),
      fn {_, meta, _} ->
        build_diagnostic(file, AST.line(meta), :enum_at_zero)
      end
    )
  end

  # --- Pattern 3: List.last in loop — only flag in hot path ---

  # Known-small AST structure variables — List.last on these is always O(1)-equivalent
  @small_list_vars [
    :args,
    :aliases,
    :parts,
    :meta,
    :opts,
    :clauses,
    :params,
    :fields,
    :items,
    :mod_parts,
    :body,
    :path,
    :exprs
  ]

  defp find_list_last_in_loop(ast, file) do
    find_in_loops(ast, file, :list_last_in_loop, fn
      {{:., _, [{:__aliases__, _, [:List]}, :last]}, _, [{var, _, ctx}]}
      when is_atom(var) and is_atom(ctx) ->
        var not in @small_list_vars

      {{:., _, [{:__aliases__, _, [:List]}, :last]}, _, _} ->
        true

      _ ->
        false
    end)
  end

  # --- Pattern 4: Enum.reverse |> hd() or hd(Enum.reverse(list)) ---

  defp find_reverse_then_hd(ast, file) do
    piped = find_reverse_pipe_hd(ast, file)
    wrapped = find_hd_wrapping_reverse(ast, file)
    piped ++ wrapped
  end

  # Enum.reverse(list) |> hd()
  defp find_reverse_pipe_hd(ast, file) do
    Enum.map(
      AST.find_all(ast, fn
        {:|>, _,
         [
           {{:., _, [{:__aliases__, _, [:Enum]}, :reverse]}, _, _},
           {:hd, _, _}
         ]} ->
          true

        _ ->
          false
      end),
      fn {_, meta, _} ->
        build_diagnostic(file, AST.line(meta), :reverse_then_hd)
      end
    )
  end

  # hd(Enum.reverse(list))
  defp find_hd_wrapping_reverse(ast, file) do
    Enum.map(
      AST.find_all(ast, fn
        {:hd, _, [{{:., _, [{:__aliases__, _, [:Enum]}, :reverse]}, _, _}]} -> true
        _ -> false
      end),
      fn {:hd, meta, _} ->
        build_diagnostic(file, AST.line(meta), :reverse_then_hd)
      end
    )
  end

  # --- Pattern 5: List.insert_at(list, -1, item) — always flag ---

  defp find_insert_at_neg1(ast, file) do
    Enum.map(
      AST.find_all(ast, fn
        {{:., _, [{:__aliases__, _, [:List]}, :insert_at]}, _, [_, idx, _]} ->
          neg_one?(idx)

        _ ->
          false
      end),
      fn {_, meta, _} ->
        build_diagnostic(file, AST.line(meta), :insert_at_neg1)
      end
    )
  end

  # --- Pattern 6: List.delete_at in loop — only in hot path ---

  defp find_delete_at_in_loop(ast, file) do
    find_in_loops(ast, file, :delete_at_in_loop, fn
      {{:., _, [{:__aliases__, _, [:List]}, :delete_at]}, _, _} -> true
      _ -> false
    end)
  end

  # --- Pattern 7: Enum.at(list, variable) in loop — only in hot path ---

  defp find_enum_at_variable_in_loop(ast, file) do
    find_in_loops(ast, file, :enum_at_variable_in_loop, fn
      {{:., _, [{:__aliases__, _, [:Enum]}, :at]}, _, [_, index]} ->
        variable_index?(index)

      _ ->
        false
    end)
  end

  defp variable_index?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp variable_index?(_), do: false

  defp neg_one?(-1), do: true
  defp neg_one?({:__block__, _, [-1]}), do: true
  defp neg_one?({:-, _, [1]}), do: true
  defp neg_one?({:-, _, [{:__block__, _, [1]}]}), do: true
  defp neg_one?(_), do: false

  # --- Loop detection — delegates to shared LoopDetection helper ---
  # Covers Enum, Stream, :lists, for, receive, Task.async_stream.

  defp find_in_loops(ast, file, kind, predicate) do
    LoopDetection.find_in_loops(ast, predicate)
    |> Enum.map(fn {_, meta} -> build_diagnostic(file, AST.line(meta), kind) end)
  end

  # --- Diagnostics ---

  defp build_diagnostic(file, line, :append_via_concat) do
    Diagnostic.warning("6.50",
      title: "Inefficient list append via ++",
      message: "`list ++ [item]` is O(n) — copies the entire left list",
      why:
        "Elixir lists are singly-linked. Appending with ++ must traverse and copy " <>
          "the entire left list every time. In a loop this becomes O(n^2). " <>
          "Prepend with [item | list] and Enum.reverse/1 at the end, or use IO lists.",
      alternatives: [
        Fix.new(
          summary: "Prepend and reverse",
          detail:
            "Replace `acc ++ [item]` with `[item | acc]` in the loop, " <>
              "then call `Enum.reverse(acc)` after the loop completes.",
          applies_when: "Accumulating items in a loop or reduce."
        ),
        Fix.new(
          summary: "Use IO lists for string building",
          detail:
            "If building output, collect `[item | acc]` and pass directly to " <>
              "IO.iodata_to_binary/1 or IO functions that accept iodata.",
          applies_when: "Building string output from parts."
        )
      ],
      tags: [:perf],
      file: file,
      line: line
    )
  end

  defp build_diagnostic(file, line, :concat_accumulator) do
    Diagnostic.warning("6.50",
      title: "List ++ in loop accumulator",
      message: "`acc ++ list` inside a loop copies the accumulator every iteration — O(n^2)",
      why:
        "The ++ operator copies the entire left-hand list. When used as an accumulator " <>
          "in Enum.reduce or similar, each iteration copies the growing result. " <>
          "For 1000 items this means ~500,000 copy operations instead of 1000.",
      alternatives: [
        Fix.new(
          summary: "Prepend and reverse",
          detail:
            "Replace `acc ++ items` with `Enum.reverse(items) ++ acc` or " <>
              "`[item | acc]`, then `Enum.reverse(result)` after the loop.",
          applies_when: "Order matters in the final result."
        ),
        Fix.new(
          summary: "Use Enum.flat_map instead of reduce + ++",
          detail: "`Enum.flat_map(items, &transform/1)` handles the common case.",
          applies_when: "Each iteration produces a list to be concatenated."
        )
      ],
      tags: [:perf],
      file: file,
      line: line
    )
  end

  defp build_diagnostic(file, line, :enum_at_zero) do
    Diagnostic.info("6.50",
      title: "Enum.at(list, 0) for first element",
      message: "`Enum.at(list, 0)` traverses needlessly — use `hd(list)` or `[h | _] = list`",
      why:
        "Enum.at/2 is a generic function that works on any enumerable. For lists, " <>
          "getting the first element is O(1) with `hd/1` or pattern matching " <>
          "`[head | _] = list`. Enum.at starts the Enumerable protocol machinery.",
      alternatives: [
        Fix.new(
          summary: "Use hd/1 or pattern match",
          detail: "`Enum.at(list, 0)` -> `hd(list)` or `[h | _] = list`",
          applies_when: "The collection is known to be a list."
        )
      ],
      tags: [:perf],
      file: file,
      line: line
    )
  end

  defp build_diagnostic(file, line, :list_last_in_loop) do
    Diagnostic.info("6.50",
      title: "List.last/1 in loop",
      message:
        "`List.last/1` inside a loop is O(n) per iteration — consider a different data structure",
      why:
        "List.last/1 traverses the entire list to reach the final element. " <>
          "Inside a loop this compounds to O(n*m) where n is the loop size and " <>
          "m is the list length. If you need frequent last-element access, " <>
          "reverse the list, use a tuple, or store the last element separately.",
      alternatives: [
        Fix.new(
          summary: "Reverse the list or track the last element",
          detail:
            "If the list doesn't change, call Enum.reverse/1 once and use hd/1. " <>
              "Or store the last element in a separate variable.",
          applies_when: "List.last/1 is called inside Enum callbacks or for comprehensions."
        )
      ],
      tags: [:perf],
      file: file,
      line: line
    )
  end

  defp build_diagnostic(file, line, :reverse_then_hd) do
    Diagnostic.info("6.50",
      title: "Enum.reverse |> hd — use List.last/1",
      message: "`Enum.reverse(list) |> hd()` is a verbose way to get the last element",
      why:
        "Both `Enum.reverse(list) |> hd()` and `hd(Enum.reverse(list))` reverse " <>
          "the entire list just to get the last element. `List.last/1` does the " <>
          "same traversal but expresses intent clearly and avoids building the " <>
          "reversed intermediate list.",
      alternatives: [
        Fix.new(
          summary: "Use List.last/1",
          detail: "`Enum.reverse(list) |> hd()` -> `List.last(list)`",
          applies_when: "Always — List.last/1 is clearer and avoids the intermediate list."
        )
      ],
      tags: [:perf],
      file: file,
      line: line
    )
  end

  defp build_diagnostic(file, line, :insert_at_neg1) do
    Diagnostic.warning("6.50",
      title: "List.insert_at(list, -1, item) — O(n) append",
      message: "`List.insert_at(list, -1, item)` is O(n) — same as `list ++ [item]`",
      why:
        "List.insert_at with index -1 appends to the end, which requires traversing " <>
          "the entire list. This is the same O(n) cost as `list ++ [item]`. " <>
          "Prepend with `[item | list]` and reverse at the end.",
      alternatives: [
        Fix.new(
          summary: "Prepend and reverse",
          detail:
            "Replace `List.insert_at(list, -1, item)` with `[item | list]` " <>
              "and call `Enum.reverse/1` when the final order is needed.",
          applies_when: "Accumulating items where order matters."
        )
      ],
      tags: [:perf],
      file: file,
      line: line
    )
  end

  defp build_diagnostic(file, line, :delete_at_in_loop) do
    Diagnostic.info("6.50",
      title: "List.delete_at/2 in loop",
      message: "`List.delete_at/2` inside a loop is O(n) per call — consider MapSet or Map",
      why:
        "List.delete_at/2 must traverse up to `index` elements and rebuild the list. " <>
          "Repeated deletion in a loop gives O(n*m) performance. If you need " <>
          "frequent random deletion, use a MapSet (for unique values) or a Map " <>
          "(for indexed access).",
      alternatives: [
        Fix.new(
          summary: "Use MapSet or Map for frequent deletions",
          detail:
            "Convert to MapSet and use MapSet.delete/2 for O(log n) deletion, " <>
              "or use a Map with integer keys for indexed access.",
          applies_when: "List.delete_at/2 is called inside Enum callbacks or for comprehensions."
        )
      ],
      tags: [:perf],
      file: file,
      line: line
    )
  end

  defp build_diagnostic(file, line, :enum_at_variable_in_loop) do
    Diagnostic.info("6.50",
      title: "Enum.at/2 with variable index in loop",
      message: "`Enum.at(list, index)` inside a loop is O(n) per access — consider Map or tuple",
      why:
        "Random access on a linked list is O(n). Inside a loop, " <>
          "this compounds to O(n*m). If you need frequent indexed access, " <>
          "convert to a tuple (elem/2 is O(1)) or a Map with integer keys.",
      alternatives: [
        Fix.new(
          summary: "Convert to tuple or Map for random access",
          detail:
            "Use `List.to_tuple(list)` and `elem(tuple, i)` for O(1) access, " <>
              "or `list |> Enum.with_index() |> Map.new(fn {v, i} -> {i, v} end)`.",
          applies_when:
            "Enum.at/2 with a variable index inside Enum callbacks or for comprehensions."
        )
      ],
      tags: [:perf],
      file: file,
      line: line
    )
  end
end
