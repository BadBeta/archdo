defmodule Archdo.Rules.CE.VolatileNoRetry do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-35. For each volatile call, walk the
  # enclosing function body for retry/breaker patterns. If neither
  # appears, fire — transient failures (network blips, downstream
  # rate limits, vendor 503s) become user-visible errors; repeated
  # failures cascade without protection. The volatility classification
  # said "this dep will fail unpredictably" — ignoring that at the
  # call site is the bug.

  alias Archdo.{AST, Diagnostic, Fix, Volatility}

  @impl true
  def id, do: "CE-35"

  @impl true
  def description, do: "Volatile call without retry/circuit-breaker wrapper"

  # Default helper modules that signal retry/breaker is in scope.
  # Project overrides via `.archdo.exs` `retry_helpers` /
  # `breaker_helpers` will be added when needed.
  @retry_modules [Retry, ExBackoff]
  @breaker_modules [:fuse, Fuse, Hammer]
  @retry_function_names ~w(with_retries retry retry_with_backoff)a

  @impl true
  def analyze(file, ast, opts) do
    classification = Volatility.classification_for(file, ast, opts)

    case classification.tag == :volatile do
      true -> find_unprotected_calls(file, ast, classification)
      false -> []
    end
  end

  defp find_unprotected_calls(file, ast, classification) do
    targets = MapSet.new(classification.evidence.volatile_calls, &elem(&1, 0))

    ast
    |> AST.extract_functions(:public)
    |> Enum.flat_map(fn {name, arity, meta, _args, body} ->
      cond do
        body == nil ->
          []

        function_uses_volatile_target?(body, targets) and
            not protected_by_helper?(body) ->
          [build_diagnostic(file, AST.line(meta), name, arity, targets)]

        true ->
          []
      end
    end)
  end

  defp function_uses_volatile_target?(body, targets) do
    AST.contains?(body, fn
      {{:., _, [{:__aliases__, _, parts}, _fun]}, _, _} ->
        case Enum.all?(parts, &is_atom/1) do
          true -> MapSet.member?(targets, Module.concat(parts))
          false -> false
        end

      _ ->
        false
    end)
  end

  defp protected_by_helper?(body) do
    AST.contains?(body, fn
      # Retry.with_retries(opts, fn -> ... end)
      {{:., _, [{:__aliases__, _, parts}, fun]}, _, _}
      when is_atom(fun) ->
        Module.concat(parts) in @retry_modules and fun in @retry_function_names

      # :fuse.ask(:my_fuse, :sync) — Erlang module call
      {{:., _, [mod, _fun]}, _, _} when is_atom(mod) ->
        mod in @breaker_modules

      # literal_encoder-wrapped Erlang module
      {{:., _, [{:__block__, _, [mod]}, _fun]}, _, _} when is_atom(mod) ->
        mod in @breaker_modules

      _ ->
        false
    end)
  end

  defp build_diagnostic(file, line, name, arity, targets) do
    Diagnostic.warning("CE-35",
      title: "Volatile call without retry/circuit-breaker wrapper",
      message:
        "#{name}/#{arity} calls volatile dep(s) (#{targets |> MapSet.to_list() |> Enum.map_join(", ", &inspect/1)}) " <>
          "without a retry or circuit-breaker pattern in scope",
      why:
        "Volatile dependencies fail unpredictably — transient network blips, " <>
          "downstream rate limits, vendor 503s. Without retry/breaker the failures " <>
          "become user-visible errors immediately and cascade without protection.",
      alternatives: [
        Fix.new(
          summary: "Wrap in Retry.with_retries for transient failures",
          detail:
            "`Retry.with_retries([attempts: 3, backoff: :exponential], fn -> " <>
              "vendor_call() end)` — recovers from blips without surfacing them.",
          applies_when: "The operation is idempotent and failures are typically transient."
        ),
        Fix.new(
          summary: "Add a circuit breaker (:fuse / Fuse) for repeated failures",
          detail:
            "Wrap the call in `:fuse.ask/2` and melt the fuse on failure. Stops " <>
              "hammering a dead vendor and shedding load until the breaker resets.",
          applies_when: "The dependency is downstream-critical and may stay degraded."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-35"],
      context: %{function: "#{name}/#{arity}", targets: MapSet.to_list(targets)},
      file: file,
      line: line
    )
  end
end
