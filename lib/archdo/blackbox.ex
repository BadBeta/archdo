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

  alias Archdo.{AST, InputGuard}

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
    specs = AST.spec_keys(ast)
    fns = AST.extract_functions(ast, :public)
    catch_all_set = collect_catch_alls(fns)

    Enum.map(fns, fn {name, arity, _meta, args, body} ->
      components = score_function(body, name, arity, specs, args, catch_all_set)
      total = product(components)
      {name, arity, total, components}
    end)
  end

  # Set of {name, arity} for which a catch-all clause exists.
  defp collect_catch_alls(fns) do
    fns
    |> Enum.filter(fn {_name, _arity, _meta, args, _body} ->
      args == nil or args_are_catch_all?(args)
    end)
    |> Enum.map(fn {name, arity, _, _, _} -> {name, arity} end)
    |> MapSet.new()
  end

  # All args are bare variables / underscores (no atom / tuple / map
  # patterns matching specific shapes).
  defp args_are_catch_all?(args) when is_list(args) do
    Enum.all?(args, &AST.catch_all_arg?/1)
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

  # --- M-Aux4 module + context verdicts ---

  @type leak_reason :: float() | :unguarded_input
  @type module_verdict ::
          :building_block
          | {:leaks_at, [{atom(), arity(), leak_reason()}]}

  @building_block_threshold 0.9

  @doc """
  Module-level verdict combining structural Blackbox score (min-not-mean
  across public function scores) AND input-guard analysis (M-Plan6).

  A module IS a building block only when:
    1. EVERY public function scores ≥ #{@building_block_threshold}
       on the structural six-component check, AND
    2. EVERY public function (with arity > 0) constrains its input
       domain (guard, all-specific patterns, or `{:error, _}` fallback).

  Failures are reported via `{:leaks_at, [{name, arity, reason}, ...]}`
  where `reason` is either a `float()` (structural score below threshold)
  or `:unguarded_input` (passes the structural check but accepts any
  input — flagged by Archdo.InputGuard).

  Modules with no public functions are vacuously building blocks.
  """
  @spec module_verdict(Macro.t()) :: module_verdict()
  def module_verdict(ast) do
    case score_module(ast) do
      [] ->
        :building_block

      scores ->
        structural_leaks =
          scores
          |> Enum.filter(fn {_n, _a, score, _c} -> score < @building_block_threshold end)
          |> Enum.map(fn {n, a, score, _c} -> {n, a, score} end)

        # §§ elixir-implementing: §2.1 — multi-step shape resolution.
        # Combine structural leaks with input-safety leaks. The input
        # check only runs on functions that PASSED the structural check
        # (otherwise their structural failure is the dominant story).
        structural_leak_keys = MapSet.new(structural_leaks, fn {n, a, _} -> {n, a} end)
        clauses_by_key = InputGuard.collect_clauses(ast)

        input_leaks =
          scores
          |> Enum.filter(fn {n, a, score, _c} ->
            score >= @building_block_threshold and a > 0 and
              not MapSet.member?(structural_leak_keys, {n, a})
          end)
          |> Enum.flat_map(&unguarded_input_leak(&1, clauses_by_key))

        verdict_for_leaks(structural_leaks ++ input_leaks)
    end
  end

  # §§ elixir-implementing: §2.1 — boolean → multi-clause head
  defp unguarded_input_leak({n, a, _score, _c}, clauses_by_key) do
    classify_input_leak(InputGuard.any_unconstrained?(Map.get(clauses_by_key, {n, a}, [])), n, a)
  end

  defp classify_input_leak(false, _n, _a), do: []
  defp classify_input_leak(true, n, a), do: [{n, a, :unguarded_input}]

  defp verdict_for_leaks([]), do: :building_block
  defp verdict_for_leaks(list), do: {:leaks_at, list}

  @doc """
  Context-level verdict: aggregate `module_verdict/1` across every
  module whose name starts with `<context>` or `<context>.`. The
  context IS a building block when every module in its namespace is
  one. Otherwise returns `{:leaks_at, [module_name, ...]}`.

  `file_asts` is the project's `[{file, ast}, ...]` list.
  """
  @spec context_verdict([{String.t(), Macro.t()}], String.t()) ::
          :building_block | {:leaks_at, [String.t()]}
  def context_verdict(file_asts, context_module) do
    members =
      file_asts
      |> Enum.map(fn {_file, ast} -> {AST.extract_module_name(ast), ast} end)
      |> Enum.filter(fn {name, _ast} -> AST.module_under_namespace?(name, context_module) end)

    leaks =
      Enum.flat_map(members, fn {name, ast} ->
        case module_verdict(ast) do
          :building_block -> []
          {:leaks_at, _} -> [name]
        end
      end)

    case leaks do
      [] -> :building_block
      list -> {:leaks_at, Enum.sort(list)}
    end
  end

  # --- M-Aux5 boundary suggestion + refactor distance ---

  @type boundary_suggestion ::
          :building_block
          | {:extract, leaky :: [{atom(), arity()}], pure :: [{atom(), arity()}]}
          | {:refactor_in_place, %{atom() => non_neg_integer()}}

  @doc """
  Suggest the boundary of a possible building block.

  * `:building_block` — module is already a building block; nothing to do.
  * `{:extract, leaky_fns, pure_fns}` — pure functions don't depend on
    leaky ones. Extracting `leaky_fns` into an orchestrator leaves
    `pure_fns` as a building block.
  * `{:refactor_in_place, breakdown}` — pure subset is empty, OR pure
    functions call leaky ones (extraction would break callers). The
    breakdown maps each failed component to the count of public
    functions that fail it, so the user knows which kind of leak
    dominates.

  Modules with no public functions are vacuously building blocks.
  """
  @spec boundary_suggestion(Macro.t()) :: boundary_suggestion()
  def boundary_suggestion(ast) do
    case score_module(ast) do
      [] ->
        :building_block

      scores ->
        {pure, leaky} =
          Enum.split_with(scores, fn {_n, _a, score, _c} ->
            score >= @building_block_threshold
          end)

        case {pure, leaky} do
          {_, []} ->
            :building_block

          {[], _} ->
            {:refactor_in_place, leaks_breakdown(leaky)}

          {_, _} ->
            classify_extraction(ast, pure, leaky)
        end
    end
  end

  defp classify_extraction(ast, pure, leaky) do
    leaky_set = MapSet.new(leaky, fn {n, a, _, _} -> {n, a} end)
    fns = AST.extract_functions(ast, :public)

    pure_calls_leaky? =
      Enum.any?(pure, fn {name, arity, _, _} ->
        body = body_of(fns, name, arity)
        body && body_calls_any?(body, leaky_set)
      end)

    case pure_calls_leaky? do
      true ->
        {:refactor_in_place, leaks_breakdown(leaky)}

      false ->
        {:extract, name_arity_list(leaky), name_arity_list(pure)}
    end
  end

  defp body_of(fns, name, arity) do
    Enum.find_value(fns, fn
      {^name, ^arity, _meta, _args, body} -> body
      _ -> nil
    end)
  end

  # Walk the function body looking for a bare local call (no module
  # prefix) whose {name, arity} is in the leaky set.
  defp body_calls_any?(body, leaky_set) do
    {_, hit?} =
      Macro.prewalk(body, false, fn
        node, true ->
          {node, true}

        {name, _meta, args} = node, false
        when is_atom(name) and is_list(args) ->
          arity = length(args)

          case MapSet.member?(leaky_set, {name, arity}) do
            true -> {node, true}
            false -> {node, false}
          end

        node, false ->
          {node, false}
      end)

    hit?
  end

  defp name_arity_list(scores) do
    scores
    |> Enum.map(fn {n, a, _, _} -> {n, a} end)
    |> Enum.sort()
  end

  defp leaks_breakdown(leaky) do
    Enum.reduce(leaky, %{}, fn {_n, _a, _s, components}, acc ->
      Enum.reduce(components, acc, &accumulate_leaky_component/2)
    end)
  end

  # §§ elixir-implementing: §2.1 — boolean → multi-clause head on
  # whether the component value is < 1.0 (a leak) or saturated.
  defp accumulate_leaky_component({key, value}, acc) when value < 1.0,
    do: Map.update(acc, key, 1, &(&1 + 1))

  defp accumulate_leaky_component(_kv, acc), do: acc

  @doc """
  Distance from a building block, expressed as the total count of
  failed components across all public functions.

  * 0 — already a building block
  * 1 — one function fails one component
  * N — total failed components

  Useful for ranking modules by ROI of refactor.
  """
  @spec refactor_distance(Macro.t()) :: non_neg_integer()
  def refactor_distance(ast) do
    ast
    |> score_module()
    |> Enum.reduce(0, fn {_n, _a, _s, components}, acc ->
      acc + Enum.count(components, fn {_k, v} -> v < 1.0 end)
    end)
  end

  # --- per-function scoring ---

  defp score_function(body, name, arity, specs, args, catch_all_set) do
    %{
      input_closure: input_closure_score(body),
      determinism: if(contains_any?(body, all_nondeterministic()), do: 0.0, else: 1.0),
      output_completeness: spec_score(specs, {name, arity}),
      totality: totality_score(args, name, arity, catch_all_set),
      side_effect_free: if(contains_any?(body, all_side_effect()), do: 0.0, else: 1.0),
      errors_as_values: errors_as_values_score(body)
    }
  end

  # Totality = 1.0 if function is single-clause with no specific patterns
  # (impossible to FunctionClauseError on input shape) OR has a catch-all
  # clause; 0.5 otherwise (multi-clause without catch-all — risk of
  # uncovered input).
  defp totality_score(args, name, arity, catch_all_set) do
    cond do
      MapSet.member?(catch_all_set, {name, arity}) -> 1.0
      args == nil or args == [] -> 1.0
      args_are_catch_all?(args) -> 1.0
      true -> 0.5
    end
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

  # --- aggregation ---

  defp product(components) do
    components
    |> Map.values()
    |> Enum.reduce(1.0, &(&1 * &2))
  end

  defp arithmetic_mean([]), do: 0.0
  defp arithmetic_mean(list), do: Enum.sum(list) / length(list)

  # --- Group O axis 2: value ---
  # Value answers "would converting this to a building block pay off?"
  # Heuristics:
  #   * substance — bigger function bodies are higher-value to capture
  #   * role — orchestrator function names (handle_event, mount,
  #     init, perform, run, call, child_spec) → low value, those
  #     functions are SUPPOSED to compose effects
  #   * public API position — public functions in :context layers
  #     get a value boost (callers benefit from the building-block
  #     guarantee)

  @orchestrator_names ~w(
    handle_event handle_call handle_cast handle_info handle_continue
    init terminate code_change format_status start_link child_spec
    mount render call run perform
  )a

  @substance_threshold 30
  @medium_substance 10

  @doc """
  Score a function on the value axis (0.0–1.0). Inputs:
    - `body` — the function body AST
    - `name` — the function name (atom)
    - `phoenix_layer` — the file's Phoenix layer (atom or nil)
  """
  @spec value(Macro.t() | nil, atom(), atom() | nil) :: float()
  def value(body, name, phoenix_layer \\ nil)

  def value(nil, _name, _layer), do: 0.0

  def value(body, name, phoenix_layer) do
    case orchestrator_name?(name) do
      true -> 0.0
      false -> substance_score(body) + layer_boost(phoenix_layer)
    end
    |> min(1.0)
  end

  defp orchestrator_name?(name), do: name in @orchestrator_names

  defp substance_score(body) do
    size = AST.ast_size(body)

    cond do
      size >= @substance_threshold -> 0.8
      size >= @medium_substance -> 0.4
      true -> 0.0
    end
  end

  defp layer_boost(:context), do: 0.2
  defp layer_boost(:schema), do: 0.1
  defp layer_boost(_), do: 0.0

  @doc """
  Classify the value score into bands matching the possibility classifier.

      ≥ 0.7  → :high
      ≥ 0.3  → :medium
      < 0.3  → :low
  """
  @spec value_class(float()) :: :high | :medium | :low
  def value_class(v) when v >= 0.7, do: :high
  def value_class(v) when v >= 0.3, do: :medium
  def value_class(_), do: :low
end
