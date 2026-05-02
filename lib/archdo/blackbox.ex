defmodule Archdo.Blackbox do
  @moduledoc false

  # §§ elixir-planning: §6 — Blackbox composability score (Group O
  # axis 1 — "is it possible to make a building block out of this?").
  # Six components multiplied together — high score means the function
  # has every property property-based testing requires (purity,
  # determinism, closed input, total output, side-effect freedom,
  # errors as values).
  #
  # M25 ships the metric only — no rule fires from this score yet.
  # M26 will add the second axis (`:valuable`) and CE-54/55/56 quadrant
  # rules.

  alias Archdo.AST

  @type components :: %{
          input_closure: float(),
          determinism: float(),
          output_completeness: float(),
          totality: float(),
          side_effect_free: float(),
          errors_as_values: float()
        }

  @type function_score :: {atom(), arity(), float(), components()}
  @type class :: :building_block | :near_block | :mixed | :boundary

  # Hidden-input call patterns — reads of state outside the parameter list.
  @hidden_input_calls [
    {[:Application], :get_env},
    {[:Application], :fetch_env},
    {[:Application], :fetch_env!},
    {[:Application], :compile_env},
    {[:Application], :compile_env!},
    {[:Process], :get},
    {[:Process], :put},
    {[:Process], :delete}
  ]

  @hidden_input_bare_atoms [{:persistent_term, :get}, {:ets, :lookup}, {:ets, :tab2list}]

  # Non-deterministic primitives — same inputs, different outputs.
  @nondeterministic_calls [
    {[:DateTime], :utc_now},
    {[:DateTime], :now},
    {[:NaiveDateTime], :utc_now},
    {[:Date], :utc_today},
    {[:Time], :utc_now},
    {[:System], :system_time},
    {[:System], :monotonic_time},
    {[:System], :os_time},
    {[:System], :unique_integer}
  ]

  @nondeterministic_bare_atoms [
    {:rand, :uniform},
    {:rand, :uniform_real},
    {:erlang, :system_time},
    {:erlang, :unique_integer},
    {:erlang, :monotonic_time},
    {:os, :timestamp}
  ]

  # Side-effect-emitting calls — the output is no longer the only effect.
  @side_effect_calls [
    {[:Logger], :debug},
    {[:Logger], :info},
    {[:Logger], :notice},
    {[:Logger], :warning},
    {[:Logger], :error},
    {[:Phoenix, :PubSub], :broadcast},
    {[:Phoenix, :PubSub], :local_broadcast},
    {[:Repo], :insert},
    {[:Repo], :update},
    {[:Repo], :delete},
    {[:Repo], :insert!},
    {[:Repo], :update!},
    {[:Repo], :delete!}
  ]

  @side_effect_bare_atoms [{:telemetry, :execute}, {:ets, :insert}, {:ets, :delete}]

  @doc """
  Score every public function in the module AST.
  Returns a list of `{name, arity, score, components}` tuples.
  """
  @spec score_module(Macro.t()) :: [function_score()]
  def score_module(ast) do
    specs = collect_specs(ast)

    ast
    |> AST.extract_functions(:public)
    |> Enum.map(fn {name, arity, _meta, _args, body} ->
      components = score_function(body, name, arity, specs)
      total = product(components)
      {name, arity, total, components}
    end)
  end

  @doc """
  Compute the blackbox possibility score for a single function or
  module AST. For convenience: returns the geometric mean across
  all public functions if given a module AST.
  """
  @spec possibility(Macro.t()) :: float()
  def possibility(ast) do
    case score_module(ast) do
      [] -> 0.0
      scores -> scores |> Enum.map(fn {_, _, s, _} -> s end) |> arithmetic_mean()
    end
  end

  @doc "Map a possibility score (0.0–1.0) to a class label."
  @spec classify(float()) :: class()
  def classify(score) when score >= 0.9, do: :building_block
  def classify(score) when score >= 0.7, do: :near_block
  def classify(score) when score >= 0.4, do: :mixed
  def classify(_), do: :boundary

  # --- per-function scoring ---

  defp score_function(body, name, arity, specs) do
    %{
      input_closure: input_closure_score(body),
      determinism: if(contains_any?(body, all_nondeterministic()), do: 0.0, else: 1.0),
      output_completeness: spec_score(specs, {name, arity}),
      totality: 1.0,
      side_effect_free: if(contains_any?(body, all_side_effect()), do: 0.0, else: 1.0),
      errors_as_values: errors_as_values_score(body)
    }
  end

  defp input_closure_score(body) do
    n = body |> count_calls(all_hidden_input()) |> min(5)
    max(0.0, 1.0 - 0.2 * n)
  end

  defp errors_as_values_score(body) do
    has_raise =
      AST.contains?(body, fn
        {:raise, _, _} -> true
        _ -> false
      end)

    if has_raise, do: 0.0, else: 1.0
  end

  defp spec_score(specs, key) do
    case MapSet.member?(specs, key) do
      true -> 1.0
      false -> 0.0
    end
  end

  # --- AST-walking helpers ---

  defp all_hidden_input, do: {@hidden_input_calls, @hidden_input_bare_atoms}
  defp all_nondeterministic, do: {@nondeterministic_calls, @nondeterministic_bare_atoms}
  defp all_side_effect, do: {@side_effect_calls, @side_effect_bare_atoms}

  defp contains_any?(body, {alias_calls, bare_calls}) do
    AST.contains?(body, &call_in_set?(&1, alias_calls, bare_calls))
  end

  defp count_calls(body, {alias_calls, bare_calls}) do
    {_, count} =
      Macro.prewalk(body, 0, fn node, acc ->
        case call_in_set?(node, alias_calls, bare_calls) do
          true -> {node, acc + 1}
          false -> {node, acc}
        end
      end)

    count
  end

  defp call_in_set?(
         {{:., _, [{:__aliases__, _, parts}, fun]}, _, _},
         alias_calls,
         _bare
       )
       when is_list(parts) and is_atom(fun) do
    {parts, fun} in alias_calls
  end

  defp call_in_set?({{:., _, [mod, fun]}, _, _}, _alias, bare_calls)
       when is_atom(mod) and is_atom(fun) do
    {mod, fun} in bare_calls
  end

  # literal_encoder wraps bare-atom Erlang module references.
  defp call_in_set?(
         {{:., _, [{:__block__, _, [mod]}, fun]}, _, _},
         _alias,
         bare_calls
       )
       when is_atom(mod) and is_atom(fun) do
    {mod, fun} in bare_calls
  end

  defp call_in_set?(_, _, _), do: false

  # --- spec collection ---

  defp collect_specs(ast) do
    {_, set} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:@, _, [{:spec, _, [{:"::", _, [{name, _, args}, _ret]}]}]} = node, acc
        when is_atom(name) and is_list(args) ->
          {node, MapSet.put(acc, {name, length(args)})}

        node, acc ->
          {node, acc}
      end)

    set
  end

  # --- aggregation ---

  defp product(components) do
    components
    |> Map.values()
    |> Enum.reduce(1.0, &(&1 * &2))
  end

  defp arithmetic_mean([]), do: 0.0
  defp arithmetic_mean(list), do: Enum.sum(list) / length(list)
end
