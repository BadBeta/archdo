defmodule Archdo.InputGuard do
  @moduledoc false

  # §§ elixir-planning: §6 — shared input-guard analyzer used by
  # both CE-57 (UnguardedBuildingBlock) and Blackbox.module_verdict
  # so the "is this clause's input domain constrained?" definition
  # lives in exactly one place.
  #
  # A clause is "constrained" when AT LEAST ONE of:
  #   - the head has a `when` guard
  #   - all argument patterns are specific (no bare-variable args)
  #   - the body's last expression is an `{:error, _}` literal
  #     (clause is the explicit error fallback)
  #
  # A function is "well-guarded" when EVERY clause is constrained.

  alias Archdo.AST

  @doc """
  Walk an AST and return `%{{name, arity} => [clause, ...]}` for every
  `def`. A clause is `%{args, guard?, body, meta}`.
  """
  @spec collect_clauses(Macro.t()) :: %{{atom(), arity()} => [map()]}
  def collect_clauses(ast) do
    {_, by_key} =
      Macro.prewalk(ast, %{}, fn
        # Guarded def: {:def, meta, [{:when, _, [{name, _, args}, _guard]}, body]}
        {:def, meta, [{:when, _, [{name, _, args} | _]}, body]} = node, acc
        when is_atom(name) and is_list(args) ->
          clause = %{args: args, guard?: true, body: body, meta: meta}
          {node, Map.update(acc, {name, length(args)}, [clause], &(&1 ++ [clause]))}

        # Plain def: {:def, meta, [{name, _, args}, body]}
        {:def, meta, [{name, _, args}, body]} = node, acc
        when is_atom(name) and is_list(args) ->
          clause = %{args: args, guard?: false, body: body, meta: meta}
          {node, Map.update(acc, {name, length(args)}, [clause], &(&1 ++ [clause]))}

        node, acc ->
          {node, acc}
      end)

    by_key
  end

  @doc """
  True when ANY clause of the given clauses list is unconstrained
  (bare-variable arg, no guard, no `{:error, _}` fallback).
  """
  @spec any_unconstrained?([map()]) :: boolean()
  def any_unconstrained?(clauses), do: Enum.any?(clauses, &unconstrained?/1)

  defp unconstrained?(%{guard?: true}), do: false

  defp unconstrained?(%{args: args, body: body}) do
    not all_specific_args?(args) and not returns_error_tuple?(body)
  end

  # All arguments are specific patterns (atoms, structs, tuples,
  # literal numbers, etc.) — NO bare variables. A single bare variable
  # arg breaks the constraint.
  defp all_specific_args?(args) when is_list(args) do
    Enum.all?(args, &specific_arg?/1)
  end

  defp specific_arg?({:_, _, ctx}) when is_atom(ctx), do: false
  defp specific_arg?({var, _, ctx}) when is_atom(var) and is_atom(ctx), do: false
  defp specific_arg?(_), do: true

  # The clause body's last expression is a literal `{:error, _}` tuple.
  # Handles bare-parser and literal_encoder-wrapped shapes.
  defp returns_error_tuple?(body) do
    case last_expression(body) do
      {{:__block__, _, [:error]}, _} -> true
      {:error, _} -> true
      _ -> false
    end
  end

  defp last_expression(body) when is_list(body) do
    case AST.do_body(body) do
      {:__block__, _, statements} -> List.last(statements)
      single -> single
    end
  end

  defp last_expression({:__block__, _, statements}), do: List.last(statements)
  defp last_expression(single), do: single
end
