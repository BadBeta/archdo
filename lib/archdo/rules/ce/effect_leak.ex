defmodule Archdo.Rules.CE.EffectLeak do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-56. A function whose Blackbox score
  # would be ≥ 0.9 EXCEPT for a single observability side-effect call
  # (Logger, :telemetry.execute, or Phoenix.PubSub.broadcast). The
  # diagnostic is sharper than "improve this function": it's "this one
  # call is keeping a building block from existing." The fix moves the
  # effect to the orchestrating layer; the inner function then becomes
  # property-test-able, memoization-safe, and parallelizable.

  alias Archdo.{AST, Blackbox, Diagnostic, Fix}

  @max_observability_calls 2

  # Observability call signatures — alias parts → fun.
  @observability_alias_calls [
    {[:Logger], :debug},
    {[:Logger], :info},
    {[:Logger], :notice},
    {[:Logger], :warning},
    {[:Logger], :error},
    {[:Phoenix, :PubSub], :broadcast},
    {[:Phoenix, :PubSub], :local_broadcast}
  ]

  @observability_bare_calls [{:telemetry, :execute}, {:telemetry, :span}]

  @impl true
  def id, do: "CE-56"

  @impl true
  def description,
    do: "Near-blackbox function leaks via single observability effect (Logger/telemetry/PubSub)"

  @impl true
  def pack, do: :ce_composability

  @impl true
  def analyze(file, ast, _opts) do
    cond do
      AST.test_file?(file) -> []
      AST.has_marker?(ast, :archdo_no_property) -> []
      true -> find_leaks(file, ast)
    end
  end

  defp find_leaks(file, ast) do
    fns = AST.extract_functions(ast, :public)
    scores = Blackbox.score_module(ast)

    fns
    |> Enum.zip(scores)
    |> Enum.flat_map(fn {{name, arity, meta, _args, body}, {_n, _a, _total, components}} ->
      case maybe_leak(body, components) do
        nil -> []
        {effect_count, kinds} -> [build_diagnostic(file, name, arity, meta, effect_count, kinds)]
      end
    end)
  end

  # The only failed component is side_effect_free, AND the body
  # contains 1-2 observability calls and no non-observability side
  # effects.
  defp maybe_leak(_body, %{side_effect_free: 1.0}), do: nil

  defp maybe_leak(body, components) do
    other_components =
      components
      |> Map.delete(:side_effect_free)
      |> Map.values()

    case Enum.all?(other_components, &(&1 >= 0.9)) do
      false ->
        nil

      true ->
        {obs, total} = count_effects(body)

        cond do
          obs == 0 -> nil
          # Mismatch: there are non-observability effects. Not a clean leak.
          obs != total -> nil
          obs > @max_observability_calls -> nil
          true -> {obs, observability_kinds(body)}
        end
    end
  end

  # Returns {observability_count, total_side_effect_count}.
  defp count_effects(body) do
    {_, {obs, total}} =
      Macro.prewalk(body, {0, 0}, fn
        node, {obs, total} ->
          cond do
            observability_call?(node) -> {node, {obs + 1, total + 1}}
            other_side_effect?(node) -> {node, {obs, total + 1}}
            true -> {node, {obs, total}}
          end
      end)

    {obs, total}
  end

  defp observability_call?({{:., _, [{:__aliases__, _, parts}, fun]}, _, _}) do
    {parts, fun} in @observability_alias_calls
  end

  defp observability_call?({{:., _, [target, fun]}, _, _}) do
    target = AST.unwrap_atom(target)
    is_atom(target) and {target, fun} in @observability_bare_calls
  end

  defp observability_call?(_), do: false

  defp other_side_effect?({{:., _, [{:__aliases__, _, [:Repo]}, fun]}, _, _})
       when fun in [:insert, :update, :delete, :insert!, :update!, :delete!],
       do: true

  defp other_side_effect?({{:., _, [target, fun]}, _, _}) do
    target = AST.unwrap_atom(target)
    is_atom(target) and {target, fun} in [{:ets, :insert}, {:ets, :delete}]
  end

  defp other_side_effect?(_), do: false

  defp observability_kinds(body) do
    {_, kinds} =
      Macro.prewalk(body, MapSet.new(), fn
        {{:., _, [{:__aliases__, _, [:Logger]}, _]}, _, _} = node, acc ->
          {node, MapSet.put(acc, "Logger")}

        {{:., _, [{:__aliases__, _, [:Phoenix, :PubSub]}, _]}, _, _} = node, acc ->
          {node, MapSet.put(acc, "Phoenix.PubSub")}

        {{:., _, [target, _]}, _, _} = node, acc ->
          case AST.unwrap_atom(target) do
            :telemetry -> {node, MapSet.put(acc, ":telemetry")}
            _ -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    kinds |> MapSet.to_list() |> Enum.sort()
  end

  defp build_diagnostic(file, name, arity, meta, count, kinds) do
    kinds_str = Enum.join(kinds, ", ")

    Diagnostic.info("CE-56",
      title: "Effect leak in near-blackbox function",
      message:
        "#{name}/#{arity}: would be a building block except for #{count} " <>
          "observability call(s) (#{kinds_str}). Move the effect to the caller and " <>
          "the inner function becomes property-test-able, memoization-safe, parallelizable.",
      why:
        "The function has every other property a building block needs (closed " <>
          "input, deterministic, total, errors-as-values, spec). The single " <>
          "observability call (Logger / telemetry / PubSub) is the only thing " <>
          "keeping it from `score = 1.0`. The fix is mechanical: rename the " <>
          "function to `do_X` or `compute_X` (now a building block), and have the " <>
          "outer `X` be a thin orchestrator that wraps the call with the effect.",
      alternatives: [
        Fix.new(
          summary: "Move the observability call to a thin wrapper",
          detail:
            "Rename inner: `def do_#{name}(args), do: ...` (no Logger/telemetry — " <>
              "now scores 1.0). Outer wrapper: `def #{name}(args) do " <>
              "result = do_#{name}(args); Logger.info(..., result: result); result end`. " <>
              "Inner is property-testable; outer composes the effect.",
          applies_when: "The effect is observability and the function has substance to property-test."
        ),
        Fix.new(
          summary: "Mark @archdo_no_property if the effect IS the function's job",
          detail:
            "If logging IS what the function does (e.g. `MyApp.Audit.record/1`), " <>
              "declare it: `@archdo_no_property \"function's job is to log\"` at " <>
              "module level.",
          applies_when: "The effect is essential to the function's contract."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-56"],
      context: %{function: "#{name}/#{arity}", observability_calls: count, kinds: kinds},
      file: file,
      line: AST.line(meta)
    )
  end
end
