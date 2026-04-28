defmodule Archdo.Rules.Helpers.LoopDetection do
  @moduledoc """
  Shared loop/iteration construct detection for performance-sensitive rules.

  Detects ALL forms of iteration in Elixir and Erlang:
  - Enum.* callbacks (map, reduce, filter, each, flat_map, etc.)
  - Stream.* callbacks (map, filter, transform, each, etc.)
  - for comprehensions
  - Task.async_stream
  - :lists.* Erlang stdlib (map, foldl, foldr, filter, foreach, etc.)
  - GenServer callbacks (handle_call/cast/info/continue) as hot paths
  - receive blocks (explicit message loops)
  - Direct recursion (functions calling themselves)
  """

  alias Archdo.AST

  # Enum functions that iterate over a collection with a callback
  @enum_fns [
    :map,
    :each,
    :reduce,
    :flat_map,
    :filter,
    :reject,
    :any?,
    :all?,
    :find,
    :find_value,
    :find_index,
    :map_reduce,
    :reduce_while,
    :sort_by,
    :min_by,
    :max_by,
    :group_by,
    :count,
    :sum_by,
    :uniq_by,
    :dedup_by,
    :frequencies_by,
    :map_join,
    :map_intersperse,
    :scan,
    :with_index,
    :zip_with,
    :zip_reduce,
    :map_every,
    :chunk_by,
    :chunk_while,
    :take_while,
    :drop_while
  ]

  # Stream functions that iterate lazily with a callback
  @stream_fns [
    :map,
    :each,
    :filter,
    :reject,
    :flat_map,
    :transform,
    :unfold,
    :scan,
    :with_index,
    :chunk_while,
    :dedup_by,
    :uniq_by,
    :take_while,
    :drop_while,
    :map_every,
    :zip_with,
    :resource
  ]

  # Erlang :lists functions that iterate with a callback
  @lists_fns [
    :map,
    :foldl,
    :foldr,
    :filter,
    :foreach,
    :filtermap,
    :flatmap,
    :any,
    :all,
    :search,
    :mapfoldl,
    :mapfoldr,
    :sort,
    :usort,
    :keymap,
    :keysort,
    :partition,
    :splitwith,
    :takewhile,
    :dropwhile,
    :zipwith
  ]

  # GenServer callbacks that execute on every message (hot paths)
  @genserver_callbacks [:handle_call, :handle_cast, :handle_info, :handle_continue]

  @doc "All Enum loop function atoms."
  def enum_fns, do: @enum_fns

  @doc "All Stream loop function atoms."
  def stream_fns, do: @stream_fns

  @doc "All Erlang :lists loop function atoms."
  def lists_fns, do: @lists_fns

  @doc "GenServer callback atoms (hot paths)."
  def genserver_callbacks, do: @genserver_callbacks

  @doc """
  Find occurrences of `predicate` inside any loop construct in the AST.

  Returns a list of `{node, meta}` tuples for each match found inside a loop body.
  The predicate receives an AST node and returns boolean.

  Detects: Enum.*, Stream.*, :lists.*, for, Task.async_stream, receive, recursion.
  """
  @spec find_in_loops(Macro.t(), (Macro.t() -> boolean())) :: [{Macro.t(), keyword()}]
  def find_in_loops(ast, predicate) do
    {_, hits} =
      Macro.prewalk(ast, [], fn
        # Enum.<fn>(_, callback)
        {{:., _, [{:__aliases__, _, [:Enum]}, func]}, _meta, args} = node, acc
        when func in @enum_fns and is_list(args) ->
          {node, find_in_callbacks(args, predicate) ++ acc}

        # Stream.<fn>(_, callback)
        {{:., _, [{:__aliases__, _, [:Stream]}, func]}, _meta, args} = node, acc
        when func in @stream_fns and is_list(args) ->
          {node, find_in_callbacks(args, predicate) ++ acc}

        # Task.async_stream(enum, callback, opts)
        {{:., _, [{:__aliases__, _, [:Task]}, :async_stream]}, _meta, args} = node, acc
        when is_list(args) ->
          {node, find_in_callbacks(args, predicate) ++ acc}

        # :lists.<fn>(callback, list) or :lists.<fn>(list, callback)
        {{:., _, [:lists, func]}, _meta, args} = node, acc
        when func in @lists_fns and is_list(args) ->
          {node, find_in_callbacks(args, predicate) ++ acc}

        # for comprehension — check do block
        {:for, _meta, args} = node, acc when is_list(args) ->
          case extract_do_block(args) do
            nil -> {node, acc}
            body -> {node, find_matches(body, predicate) ++ acc}
          end

        # receive block — each clause body is a hot path
        {:receive, _meta, [[do: clauses]]} = node, acc when is_list(clauses) ->
          hits =
            Enum.flat_map(clauses, fn {:->, _, [_pattern, body]} ->
              find_matches(body, predicate)
            end)

          {node, hits ++ acc}

        node, acc ->
          {node, acc}
      end)

    hits
  end

  @doc """
  Find occurrences of `predicate` inside GenServer callback bodies.

  These are hot paths — called on every message the process receives.
  """
  @spec find_in_genserver_callbacks(Macro.t(), (Macro.t() -> boolean())) :: [
          {Macro.t(), keyword()}
        ]
  def find_in_genserver_callbacks(ast, predicate) do
    callbacks = AST.extract_callbacks(ast)

    Enum.flat_map(@genserver_callbacks, fn callback_name ->
      case Map.get(callbacks, callback_name) do
        nil ->
          []

        clauses when is_list(clauses) ->
          Enum.flat_map(clauses, fn {_meta, _args, body} ->
            case body do
              nil -> []
              _ -> find_matches(body, predicate)
            end
          end)
      end
    end)
  end

  @doc """
  Find occurrences of `predicate` inside recursive function bodies.

  A recursive function is one where any clause's body calls itself.
  These are iteration constructs — the BEAM's loops.
  """
  @spec find_in_recursive_fns(Macro.t(), (Macro.t() -> boolean())) :: [{Macro.t(), keyword()}]
  def find_in_recursive_fns(ast, predicate) do
    # Per-clause analysis: only flag matches inside a clause that itself
    # contains a *looping* self-call. A "looping" self-call passes at least
    # one non-literal argument — that's what enables iteration.
    #
    # This excludes the catch-all-fallback dispatch pattern:
    #
    #   defp css("default"), do: "x" <> "y"   # has <> but no self-call
    #   defp css("outline"), do: "a" <> "b"   # has <> but no self-call
    #   defp css(_), do: css("default")       # has self-call but all-literal arg
    #
    # None of these clauses qualifies, so the `<>`s aren't flagged. Real
    # iterative recursion (`build([h|t], acc), do: build(t, acc <> f(h))`)
    # still fires because the self-call passes the non-literal `t`.
    fns = AST.extract_functions(ast)

    Enum.flat_map(fns, fn {name, arity, _meta, _args, body} ->
      case extract_body_ast(body) do
        nil ->
          []

        body_ast ->
          if looping_self_call?(body_ast, name, arity) do
            find_matches(body_ast, predicate)
          else
            []
          end
      end
    end)
  end

  # True if the body contains a self-call whose argument list includes at
  # least one non-literal value. Plain dispatch (`f(_), do: f("default")`)
  # has only literal args and terminates after one redirect — does not loop.
  defp looping_self_call?(body, name, arity) do
    {_, found?} =
      Macro.prewalk(body, false, fn
        node, true ->
          {node, true}

        {^name, _, args} = node, false when is_list(args) ->
          case length(args) == arity and Enum.any?(args, &non_literal_arg?/1) do
            true -> {node, true}
            false -> {node, false}
          end

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp non_literal_arg?(arg) when is_atom(arg) or is_number(arg) or is_binary(arg), do: false

  # Production parse_file/1 wraps literals as {:__block__, _, [literal]}.
  defp non_literal_arg?({:__block__, _, [inner]}) when is_atom(inner) or is_number(inner) or is_binary(inner),
    do: false

  defp non_literal_arg?(_), do: true

  defp extract_body_ast(nil), do: nil
  defp extract_body_ast(do: body), do: body
  defp extract_body_ast({:do, body}), do: body
  defp extract_body_ast(body) when is_tuple(body), do: body
  defp extract_body_ast(body) when is_list(body), do: {:__block__, [], body}
  defp extract_body_ast(_), do: nil

  @doc """
  Comprehensive search: find pattern in ALL loop constructs.

  Combines: Enum/Stream/:lists loops, for, receive, GenServer callbacks,
  and recursive functions.
  """
  @spec find_in_all_loops(Macro.t(), (Macro.t() -> boolean())) :: [{Macro.t(), keyword()}]
  def find_in_all_loops(ast, predicate) do
    find_in_loops(ast, predicate) ++
      find_in_genserver_callbacks(ast, predicate) ++
      find_in_recursive_fns(ast, predicate)
  end

  # --- Private Helpers ---

  defp find_in_callbacks(args, predicate) do
    args
    |> Enum.filter(&callback?/1)
    |> Enum.flat_map(fn callback -> find_matches(callback, predicate) end)
  end

  defp find_matches(node, predicate) do
    AST.find_all(node, predicate)
    |> Enum.flat_map(fn
      {_, meta, _} = match -> [{match, meta}]
      _non_triple -> []
    end)
  end

  defp callback?({:fn, _, _}), do: true
  defp callback?({:&, _, _}), do: true
  defp callback?(_), do: false

  defp extract_do_block(args) do
    Enum.find_value(args, fn
      [do: body] -> body
      {:do, body} -> body
      _ -> nil
    end)
  end
end
