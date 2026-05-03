defmodule Archdo.Rules.Module.UnboundedRecursion do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.23"

  @impl true
  def description,
    do:
      "Recursive function without depth guard or size limit — stack overflow risk on large input"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      find_unbounded(file, ast)
    end
  end

  defp find_unbounded(file, ast) do
    fns = AST.extract_functions(ast, :all)

    fns
    |> Enum.group_by(fn {name, arity, _, _, _} -> {name, arity} end)
    |> Enum.flat_map(fn {{name, arity}, clauses} ->
      check_unbounded(file, name, arity, clauses)
    end)
  end

  defp check_unbounded(file, name, arity, clauses) do
    is_recursive =
      Enum.any?(clauses, fn {_, _, _, _, body} ->
        body != nil and AST.has_self_call?(body, name, arity)
      end)

    diag_for_recursive(is_recursive, file, name, arity, clauses)
  end

  # §§ elixir-implementing: §2.1 — boolean → multi-clause head
  defp diag_for_recursive(false, _file, _name, _arity, _clauses), do: []

  defp diag_for_recursive(true, file, name, arity, clauses) do
    bounded? =
      all_tail_calls?(clauses, name, arity) or
        has_depth_guard?(clauses) or
        has_finite_base_case?(clauses) or
        looks_like_tree_walk?(clauses)

    diag_if_unbounded(bounded?, file, name, arity, clauses)
  end

  defp diag_if_unbounded(true, _file, _name, _arity, _clauses), do: []

  defp diag_if_unbounded(false, file, name, arity, clauses) do
    meta = clauses |> Enum.map(fn {_, _, m, _, _} -> m end) |> List.first([])
    [build_diagnostic(file, name, arity, meta)]
  end

  # Check if function has a depth/level/count parameter with a guard
  defp has_depth_guard?(clauses) do
    Enum.any?(clauses, fn {_, _, _, args, _} ->
      args != nil and has_numeric_guard_param?(args)
    end)
  end

  defp has_numeric_guard_param?(args) when is_list(args) do
    Enum.any?(args, fn
      # when depth < @max or when depth > 0 or when count <= limit
      {:when, _, [_, guard]} ->
        has_numeric_comparison?(guard)

      _ ->
        false
    end)
  end

  defp has_numeric_guard_param?(_), do: false

  defp has_numeric_comparison?({op, _, _}) when op in [:<, :>, :<=, :>=, :==], do: true

  defp has_numeric_comparison?({:and, _, [left, right]}) do
    has_numeric_comparison?(left) or has_numeric_comparison?(right)
  end

  defp has_numeric_comparison?(_), do: false

  # Simple list base case: def f([]), do: ... — bounded by input size
  defp has_finite_base_case?(clauses) do
    Enum.any?(clauses, fn {_, _, _, args, _} ->
      args != nil and matches_empty_collection?(args)
    end)
  end

  defp matches_empty_collection?(args) when is_list(args) do
    Enum.any?(args, fn
      [] -> true
      {:__block__, _, [[]]} -> true
      # match on 0 (counter exhausted)
      0 -> true
      {:__block__, _, [0]} -> true
      _ -> false
    end)
  end

  defp matches_empty_collection?(_), do: false

  # Tree traversal typically pattern matches on children/nodes
  defp looks_like_tree_walk?(clauses) do
    Enum.any?(clauses, fn {_, _, _, args, body} ->
      args_match_struct?(args) or
        (body != nil and calls_flat_map_self?(body))
    end)
  end

  defp args_match_struct?(args) when is_list(args) do
    Enum.any?(args, fn
      {:%, _, _} -> true
      _ -> false
    end)
  end

  defp args_match_struct?(_), do: false

  defp calls_flat_map_self?(body) do
    AST.contains?(body, fn
      {{:., _, [{:__aliases__, _, [:Enum]}, :flat_map]}, _, _} -> true
      _ -> false
    end)
  end

  defp all_tail_calls?(clauses, name, arity) do
    recursive_clauses =
      Enum.filter(clauses, fn {_, _, _, _, body} ->
        body != nil and AST.has_self_call?(body, name, arity)
      end)

    # If no recursive clauses, it's trivially tail-recursive
    case recursive_clauses do
      [] -> true
      _ -> not Enum.any?(recursive_clauses, &has_non_tail_call?(&1, name, arity))
    end
  end

  defp has_non_tail_call?({_, _, _, _, body}, name, arity) do
    AST.contains?(body, fn
      [{:|, _, [_, inner]}] -> AST.has_self_call?(inner, name, arity)
      {:++, _, [_, right]} -> AST.has_self_call?(right, name, arity)
      {op, _, [_, right]} when op in [:+, :-, :*, :/] -> AST.has_self_call?(right, name, arity)
      _ -> false
    end)
  end

  defp build_diagnostic(file, name, arity, meta) do
    Diagnostic.info("6.23",
      title: "Unbounded recursion without depth guard",
      message:
        "#{name}/#{arity} is recursive (non-tail) without a depth limit or finite base case",
      why:
        "Non-tail recursive functions consume one stack frame per call. Without a depth " <>
          "guard (e.g., `when depth < @max_depth`) or a guaranteed finite base case " <>
          "(matching `[]` or `0`), the recursion depth depends entirely on the input. " <>
          "If the input comes from outside the system (user data, API response, file content), " <>
          "a malicious or malformed input can crash the process with a stack overflow.",
      alternatives: [
        Fix.new(
          summary: "Add a depth parameter with a guard",
          detail:
            "```elixir\n" <>
              "@max_depth 100\n" <>
              "def walk(node, depth \\\\ 0)\n" <>
              "def walk(_node, depth) when depth > @max_depth, do: {:error, :too_deep}\n" <>
              "def walk(%{children: kids} = node, depth) do\n" <>
              "  [node | Enum.flat_map(kids, &walk(&1, depth + 1))]\n" <>
              "end\n" <>
              "```",
          applies_when: "The input structure depth is not known in advance."
        ),
        Fix.new(
          summary: "Convert to tail-recursive with accumulator",
          detail:
            "Tail-recursive functions reuse the stack frame — infinite depth is safe. " <>
              "Use an accumulator and Enum.reverse at the end.",
          applies_when: "The recursion can be restructured to tail position."
        ),
        Fix.new(
          summary: "Use Enum/Stream instead of manual recursion",
          detail: "Enum.map/reduce/flat_map handle stack management internally.",
          applies_when: "The recursion processes a flat collection."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.23"],
      context: %{function: "#{name}/#{arity}"},
      file: file,
      line: AST.line(meta)
    )
  end
end
