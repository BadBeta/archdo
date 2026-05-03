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

  # Tree traversal typically pattern matches on children/nodes. Three signals:
  #   1. A clause head matches a struct (`%Foo{} = node`)
  #   2. The body uses `Enum.flat_map` (canonical tree-walk fan-out)
  #   3. A catch-all `_` clause returns a non-recursive value — the
  #      universal "shape exhaustion" terminator used by AST walkers
  #      (Macro.prewalk-style, ast_size/1, collect_module_bodies/2, etc.)
  defp looks_like_tree_walk?(clauses) do
    Enum.any?(clauses, fn {_, _, _, args, body} ->
      args_match_struct?(args) or
        (body != nil and calls_flat_map_self?(body))
    end) or
      has_shape_exhaustion_terminator?(clauses)
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

  # A "shape exhaustion" terminator: a clause whose head is all wildcards
  # (`_` or bare variables — no destructure) AND whose body is non-recursive.
  # This is the canonical Elixir tree-walker base case:
  #
  #   def ast_size(_), do: 1
  #   def collect_module_bodies(_, acc), do: acc
  #   def collect_returns(_), do: [:other_return]
  #
  # When this clause sits alongside shape-destructuring clauses that recurse
  # on the parts, the recursion is bounded by input-shape exhaustion: every
  # path eventually hits the catch-all and stops. The shape grammar IS the
  # depth bound.
  defp has_shape_exhaustion_terminator?(clauses) do
    has_destructure = Enum.any?(clauses, fn {_, _, _, args, _} -> destructures?(args) end)
    has_terminator = Enum.any?(clauses, &catch_all_terminator?/1)
    has_destructure and has_terminator
  end

  # Clause args are all wildcards or bare variables (no nested patterns).
  defp catch_all_terminator?({_name, _arity, _meta, args, _body}) when is_list(args) do
    Enum.all?(args, &catch_all_arg?/1)
  end

  defp catch_all_terminator?(_), do: false

  defp catch_all_arg?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp catch_all_arg?(_), do: false

  # Args include at least one shape-destructuring pattern (tuple, list cons,
  # map pattern). Distinguishes a shape-walker from `def f(x), do: x + 1`.
  defp destructures?(args) when is_list(args) do
    Enum.any?(args, fn
      {a, b} when not (is_atom(a) and is_atom(b)) -> true
      {:{}, _, _} -> true
      [{:|, _, _}] -> true
      [_ | _] -> true
      [] -> true
      {:%{}, _, _} -> true
      {:%, _, _} -> true
      _ -> false
    end)
  end

  defp destructures?(_), do: false

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
