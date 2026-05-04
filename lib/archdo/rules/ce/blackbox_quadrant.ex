defmodule Archdo.Rules.CE.BlackboxQuadrant do
  @moduledoc false
  @behaviour Archdo.Rule
  @behaviour Archdo.Quadrant

  # §§ elixir-planning: §6 — CE-54 quadrant rule built on the M25
  # Blackbox engine + M26 value axis. Adopts the Archdo.Quadrant
  # primitive: axes/3 computes (possibility × value) cells per public
  # function, policy/0 declares which cells fire, finding_for/4
  # builds the diagnostic.
  #
  # Two axes:
  #   possibility — can this function BE a building block?
  #                 (M25 Blackbox.score_module)
  #   value       — would converting it pay off?
  #                 (M26 Blackbox.value)
  #
  # Policy:
  #
  #                 value:high      value:low
  #   poss:high    building block   pure but pointless
  #                (CE-55 future)   (no finding)
  #   poss:low     CE-54 fire       designed orchestrator
  #                                 (no finding)
  #
  # Only the {:low, :high} cell fires here — the function WANTS to be
  # a building block (substantial body, not an orchestrator role) but
  # ISN'T (impure, side-effects, no spec). The diagnosis includes the
  # specific component(s) that failed so the fix is concrete.
  #
  # axes/3 only emits a cell for a function when it has structural
  # failures. The policy fires unconditionally on {:low, :high}; the
  # "must have failures to be actionable" filter happens upstream so
  # finding_for/4 always has concrete components to name.
  #
  # Pack: :ce_composability (opt-in via `--packs core,ce_composability`).

  alias Archdo.{AST, Blackbox, Diagnostic, Fix, Phoenix, Quadrant}

  @impl Archdo.Rule
  def id, do: "CE-54"

  @impl Archdo.Rule
  def description,
    do: "Function wants to be a building block (high value) but isn't (low possibility)"

  @impl Archdo.Rule
  def pack, do: :ce_composability

  @impl Archdo.Rule
  def analyze(file, ast, opts) do
    case AST.test_file?(file) do
      true -> []
      false -> Quadrant.evaluate(__MODULE__, file, ast, opts)
    end
  end

  @impl Archdo.Quadrant
  def axes(file, ast, opts) do
    layer = phoenix_layer(file, ast, opts)
    scores = Blackbox.score_module(ast)
    impls = AST.impl_callbacks(ast)

    ast
    |> AST.extract_functions(:public)
    |> Enum.zip(scores)
    |> Enum.flat_map(fn {{name, arity, meta, _args, body}, {_n, _a, _possibility, components}} ->
      # value_for_function/5 corrects the value heuristic for shapes
      # that have intrinsically low building-block value: bang
      # functions (`fn!/n`) and behaviour-callback implementations.
      # Both have their signature/semantics dictated by an external
      # contract, so flagging them as "wants to be a building block
      # but isn't" is the wrong layer of analysis. The cell shifts
      # to {:low, :low} for these — no fire.
      value = Blackbox.value_for_function(body, name, arity, layer, impls)
      structural = structural_possibility(components)
      failures = structural_failures(components)

      case failures do
        [] ->
          []

        [_ | _] ->
          cell = {possibility_class(structural), Blackbox.value_class(value)}

          evidence = %{
            name: name,
            arity: arity,
            meta: meta,
            possibility: structural,
            value: value,
            components: components
          }

          [{cell, evidence}]
      end
    end)
  end

  @impl Archdo.Quadrant
  def policy do
    %{
      {:low, :high} => {:fire, :warning, "CE-54", "Function wants to be a building block but isn't"}
    }
  end

  @impl Archdo.Quadrant
  def finding_for(_cell, _action, evidence, file) do
    build_diagnostic(
      file,
      evidence.name,
      evidence.arity,
      evidence.meta,
      evidence.possibility,
      evidence.value,
      evidence.components
    )
  end

  # Filter out output_completeness from the actionable possibility —
  # if @spec is the only failure, that's CE-12 (M28) territory, not
  # CE-54. CE-54 surfaces only structural building-block failures
  # (state reads, non-determinism, side effects, raise).
  @structural_components ~w(input_closure determinism totality side_effect_free errors_as_values)a

  defp structural_possibility(components) do
    components
    |> Map.take(@structural_components)
    |> Map.values()
    |> Enum.reduce(1.0, &(&1 * &2))
  end

  defp structural_failures(components) do
    Enum.flat_map(@structural_components, fn key ->
      case Map.get(components, key, 1.0) < 1.0 do
        true -> [Atom.to_string(key)]
        false -> []
      end
    end)
  end

  defp phoenix_layer(file, ast, opts) when is_list(opts) do
    case Keyword.get(opts, :phoenix) do
      nil -> Phoenix.classify_file(file, ast).layer
      c -> c.layer
    end
  end

  defp phoenix_layer(file, ast, _), do: Phoenix.classify_file(file, ast).layer

  defp possibility_class(score) when score >= 0.7, do: :high
  defp possibility_class(score) when score >= 0.4, do: :medium
  defp possibility_class(_), do: :low

  defp build_diagnostic(file, name, arity, meta, possibility, value, components) do
    failed = failed_components(components)

    Diagnostic.warning("CE-54",
      title: "Function wants to be a building block but isn't",
      message:
        "#{name}/#{arity} has high value (#{Float.round(value, 2)}) but low " <>
          "blackbox possibility (#{Float.round(possibility, 2)}). Failed " <>
          "components: #{Enum.join(failed, ", ")}",
      why:
        "The function lives in code that should be composable (substantial body, " <>
          "non-orchestrator role) but can't currently be reasoned about as a " <>
          "building block — it has hidden inputs / non-determinism / side effects / " <>
          "missing spec / raise on legitimate inputs. The diagnosis names which " <>
          "component(s) failed so the fix is concrete.",
      alternatives: alternatives_for(failed),
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-54"],
      context: %{
        function: "#{name}/#{arity}",
        possibility: possibility,
        value: value,
        failed_components: failed
      },
      file: file,
      line: AST.line(meta)
    )
  end

  defp failed_components(components) do
    Enum.flat_map(components, fn {key, score} ->
      case score < 1.0 do
        true -> [Atom.to_string(key)]
        false -> []
      end
    end)
  end

  defp alternatives_for(failed) do
    Enum.take(Enum.flat_map(failed, &fix_for_component/1), 3)
  end

  defp fix_for_component("input_closure") do
    [
      Fix.new(
        summary: "Move config / process-state reads to the caller; pass values as parameters",
        detail:
          "Replace `Application.get_env` / `Process.get` / `:persistent_term.get` " <>
            "with explicit parameters threaded from the orchestrating layer.",
        applies_when: "The hidden input is configuration or per-process state."
      )
    ]
  end

  defp fix_for_component("determinism") do
    [
      Fix.new(
        summary: "Inject the clock or random source as a parameter",
        detail:
          "Replace `DateTime.utc_now` / `:rand.uniform` with an injected value " <>
            "passed from the caller. Tests pass a fixed value; production passes " <>
            "the real source.",
        applies_when: "The non-determinism is a single primitive (clock/random/uuid)."
      )
    ]
  end

  defp fix_for_component("output_completeness") do
    [
      Fix.new(
        summary: "Add @spec narrowing the return type",
        detail:
          "Declare a closed type union for the return value (avoid `any()` / " <>
            "`term()`). Lets Dialyzer + property tests verify the contract.",
        applies_when: "The function's return shape is statically expressible."
      )
    ]
  end

  defp fix_for_component("side_effect_free") do
    [
      Fix.new(
        summary: "Move the side effect to the orchestrating layer",
        detail:
          "Rename the inner function (e.g. `compute_x/n`) and have a thin " <>
            "wrapper (`x/n`) emit the Logger / telemetry / PubSub effect. The " <>
            "inner function becomes a building block; the wrapper composes " <>
            "effects.",
        applies_when: "The side effect is observability (Logger/telemetry/broadcast)."
      )
    ]
  end

  defp fix_for_component("errors_as_values") do
    [
      Fix.new(
        summary: "Return {:ok, _} / {:error, _} instead of raising",
        detail:
          "Reserve raise for programming errors (truly impossible inputs). For " <>
            "legitimate failure paths, return tagged tuples — composable with " <>
            "`with` chains and explicit handling.",
        applies_when: "The raise responds to legitimate caller-supplied inputs."
      )
    ]
  end

  defp fix_for_component(_), do: []
end
