defmodule Archdo.Rules.Module.StringConcatInLoop do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Rules.Helpers.LoopDetection

  @impl true
  def id, do: "6.46"

  @impl true
  def description, do: "String concatenation (<>) in loop — O(n²), use IO lists instead"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_concat_in_loops(ast, file)
    end
  end

  defp find_concat_in_loops(ast, file) do
    # Specific: Enum.reduce with string init + <> in body
    reduce_hits = find_reduce_with_string_concat(ast, file)

    # Specific: for ... reduce: "" with <> in body
    for_hits = find_for_reduce_with_concat(ast, file)

    # General: <> inside any loop construct (Stream, :lists, receive, recursion, etc.)
    # This catches patterns the specific checks miss
    general_hits = find_general_concat_in_loops(ast, file)

    reduce_hits ++ for_hits ++ general_hits
  end

  # --- Enum.reduce/Stream.transform/etc with string accumulator ---

  defp find_reduce_with_string_concat(ast, file) do
    {_, diagnostics} =
      Macro.prewalk(ast, [], fn
        # Enum.reduce(_, "", fn ..., acc -> acc <> ... end)
        {{:., _, [{:__aliases__, _, mod}, :reduce]}, meta, [_enumerable, init, {:fn, _, _} = fun]} =
            node,
        acc
        when mod in [[:Enum], [:Stream]] ->
          case string_init?(init) and fn_body_has_concat?(fun) do
            true -> {node, [build_diagnostic(file, AST.line(meta), :reduce) | acc]}
            false -> {node, acc}
          end

        # :lists.foldl(fun, "", list) or :lists.foldr(fun, "", list)
        {{:., _, [:lists, fold_fn]}, meta, [{:fn, _, _} = fun, init, _list]} = node, acc
        when fold_fn in [:foldl, :foldr] ->
          case string_init?(init) and fn_body_has_concat?(fun) do
            true -> {node, [build_diagnostic(file, AST.line(meta), :reduce) | acc]}
            false -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    diagnostics
  end

  # --- for ... reduce: "" with <> ---

  defp find_for_reduce_with_concat(ast, file) do
    {_, diagnostics} =
      Macro.prewalk(ast, [], fn
        {:for, meta, args} = node, acc when is_list(args) ->
          case for_reduce_with_concat?(args) do
            true -> {node, [build_diagnostic(file, AST.line(meta), :for_reduce) | acc]}
            false -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    diagnostics
  end

  # --- General: <> inside any loop body (catches Stream, :lists, receive, recursion) ---

  defp find_general_concat_in_loops(ast, file) do
    concat_predicate = fn
      {:<>, _, _} -> true
      _ -> false
    end

    # Exclude what the specific checks already cover (Enum.reduce with string init)
    # by checking GenServer callbacks, recursive fns, and receive blocks
    genserver_hits =
      Enum.map(LoopDetection.find_in_genserver_callbacks(ast, concat_predicate), fn {_, meta} ->
        build_diagnostic(file, AST.line(meta), :genserver_callback)
      end)

    recursion_hits =
      Enum.map(LoopDetection.find_in_recursive_fns(ast, concat_predicate), fn {_, meta} ->
        build_diagnostic(file, AST.line(meta), :recursive_fn)
      end)

    genserver_hits ++ recursion_hits
  end

  # --- Helpers ---

  defp string_init?(""), do: true
  defp string_init?({:__block__, _, [""]}), do: true
  defp string_init?(_), do: false

  defp fn_body_has_concat?({:fn, _, clauses}) when is_list(clauses) do
    Enum.any?(clauses, fn {:->, _, [_params, body]} -> body_has_concat?(body) end)
  end

  defp fn_body_has_concat?(_), do: false

  defp body_has_concat?(body) do
    AST.contains?(body, fn
      {:<>, _, _} -> true
      _ -> false
    end)
  end

  defp for_reduce_with_concat?(args) do
    reduce_init = find_reduce_init(args)

    case reduce_init do
      {:found, init} -> string_init?(init) and for_body_has_concat?(args)
      :not_found -> false
    end
  end

  defp find_reduce_init(args) do
    Enum.find_value(args, :not_found, &reduce_init_in/1)
  end

  defp reduce_init_in(keyword) when is_list(keyword) do
    case keyword[:reduce] do
      nil -> nil
      init -> {:found, init}
    end
  end

  defp reduce_init_in({:reduce, init}), do: {:found, init}
  defp reduce_init_in(_), do: nil

  defp for_body_has_concat?(args) do
    Enum.any?(args, fn
      [do: {:__block__, _, clauses}] -> Enum.any?(clauses, &body_has_concat?/1)
      [do: body] -> body_has_concat?(body)
      {:do, body} -> body_has_concat?(body)
      _ -> false
    end)
  end

  defp build_diagnostic(file, line, context) do
    detail =
      case context do
        :reduce -> "reduce with string accumulator and <> concatenation"
        :for_reduce -> "for comprehension with reduce: \"\" and <> concatenation"
        :genserver_callback -> "String <> concatenation in GenServer callback"
        :recursive_fn -> "String <> concatenation in recursive function"
      end

    Diagnostic.warning("6.46",
      title: "String concatenation in loop",
      message: "#{detail} — O(n²) copies on every iteration",
      why:
        "Each <> concatenation copies the entire accumulated string. " <>
          "For a list of n items this is O(n²). Build an IO list instead: " <>
          "collect [part | acc] and call IO.iodata_to_binary/1 once at the end.",
      alternatives: [
        Fix.new(
          summary: "Use IO lists instead of string concatenation",
          detail:
            "Replace `Enum.reduce(items, \"\", fn i, acc -> acc <> f(i) end)` " <>
              "with `items |> Enum.map(&f/1) |> IO.iodata_to_binary()`",
          applies_when: "Building a string by accumulating with <> in any loop."
        )
      ],
      tags: [:perf],
      file: file,
      line: line
    )
  end
end
