defmodule Archdo.Rules.Module.NonTailRecursion do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.20"

  @impl true
  def description,
    do: "Recursive function not in tail position — risks stack overflow on large input"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      find_non_tail_recursion(file, ast)
    end
  end

  defp find_non_tail_recursion(file, ast) do
    fns = AST.extract_functions(ast, :all)

    # Group by name to find multi-clause recursive functions
    fns
    |> Enum.group_by(fn {name, arity, _, _, _} -> {name, arity} end)
    |> Enum.flat_map(fn {{name, arity}, clauses} ->
      check_recursion(file, name, arity, clauses)
    end)
  end

  defp check_recursion(file, name, arity, clauses) do
    # Check if any clause has a non-tail recursive call
    non_tail =
      Enum.any?(clauses, fn {_, _, _, _, body} ->
        body != nil and has_non_tail_self_call?(body, name, arity)
      end)

    is_recursive =
      Enum.any?(clauses, fn {_, _, _, _, body} ->
        body != nil and AST.has_self_call?(body, name, arity)
      end)

    if is_recursive and non_tail and not AST.shape_walker?(clauses) do
      meta =
        clauses
        |> Enum.map(fn {_, _, m, _, _} -> m end)
        |> List.first([])

      [
        Diagnostic.info("6.20",
          title: "Non-tail recursion",
          message: "#{name}/#{arity} is recursive but the call is not in tail position",
          why:
            "Elixir/BEAM optimizes tail calls (last expression is the recursive call) to " <>
              "reuse the stack frame — constant memory regardless of depth. When the recursive " <>
              "call is not last (e.g., `[head | recurse(tail)]` — the cons happens after return), " <>
              "each call adds a stack frame. On large input this overflows the stack.",
          alternatives: [
            Fix.new(
              summary: "Accumulate and reverse",
              detail:
                "Use an accumulator parameter to build results, then Enum.reverse at the end:\n" <>
                  "```elixir\n" <>
                  "def transform(list), do: do_transform(list, [])\n" <>
                  "defp do_transform([], acc), do: Enum.reverse(acc)\n" <>
                  "defp do_transform([h | t], acc), do: do_transform(t, [process(h) | acc])\n" <>
                  "```",
              applies_when: "Building a list from recursive results."
            ),
            Fix.new(
              summary: "Replace with Enum.map/reduce/flat_map",
              detail:
                "Most list recursion can be replaced with Enum functions that handle " <>
                  "accumulation internally. `Enum.map/2`, `Enum.reduce/3`, `Enum.flat_map/2`.",
              applies_when: "The recursion processes a flat list (no tree/graph traversal)."
            ),
            Fix.new(
              summary: "Use Stream for lazy processing",
              detail:
                "If the input is large or infinite, `Stream.unfold/2` or `Stream.resource/3` " <>
                  "process elements lazily without stack growth.",
              applies_when: "Processing large or infinite sequences."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#6.20"],
          context: %{function: "#{name}/#{arity}"},
          file: file,
          line: AST.line(meta)
        )
      ]
    else
      []
    end
  end

  # Non-tail: recursive call appears inside a wrapper expression
  # e.g., [h | recurse(t)], result + recurse(t), Enum.concat(x, recurse(t))
  defp has_non_tail_self_call?(body, name, arity) do
    AST.contains?(body, fn
      # [head | recurse(tail)] — cons after recursive call
      [{:|, _, [_, inner]}] ->
        AST.has_self_call?(inner, name, arity)

      # result ++ recurse(tail) — append after recursive call
      {:++, _, [_, right]} ->
        AST.has_self_call?(right, name, arity)

      # result + recurse(tail) — arithmetic after recursive call
      {op, _, [_, right]} when op in [:+, :-, :*, :/] ->
        AST.has_self_call?(right, name, arity)

      # [recurse(tail) | acc] — this IS tail position (prepend), skip
      _ ->
        false
    end)
  end
end
