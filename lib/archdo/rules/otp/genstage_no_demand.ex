defmodule Archdo.Rules.OTP.GenstageNoDemand do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.35"

  @impl true
  def description, do: "GenStage consumer subscription without explicit max_demand/min_demand"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) or not genstage_module?(ast) do
      []
    else
      find_untuned_subscriptions(file, ast)
    end
  end

  # A GenStage consumer's init returns `{:consumer, state, subscribe_to: [...]}`.
  # Each subscribe_to entry should be a {producer, opts} tuple with max_demand.
  # Bare module atoms or {module, []} miss the backpressure tuning.
  defp find_untuned_subscriptions(file, ast) do
    # Look inside init/1 callbacks for subscribe_to keyword option
    callbacks = AST.extract_callbacks(ast)

    (callbacks[:init] || [])
    |> Enum.flat_map(fn {_meta, _args, body} ->
      Enum.map(find_subscribe_to(body), fn {node, line} -> {node, line, file} end)
    end)
    |> Enum.flat_map(&check_subscription/1)
  end

  defp find_subscribe_to(nil), do: []

  defp find_subscribe_to(body) do
    Enum.map(AST.find_all(body, fn
      # subscribe_to: [...]
      {:subscribe_to, _} -> true
      {{:__block__, _, [:subscribe_to]}, _} -> true
      _ -> false
    end), fn
      {:subscribe_to, value} -> {value, 1}
      {{:__block__, _, [:subscribe_to]}, value} -> {value, 1}
    end)
  end

  defp check_subscription({value, line, file}) do
    case extract_list(value) do
      nil ->
        []

      [] ->
        []

      items when is_list(items) ->
        items
        |> Enum.reject(&has_max_demand?/1)
        |> case do
          [] ->
            []

          untuned ->
            [
              Diagnostic.info("5.35",
                title: "GenStage consumer without max_demand",
                message:
                  "GenStage consumer subscribes to #{length(untuned)} producer(s) without an explicit max_demand",
                why:
                  "The default `max_demand: 1000` lets the consumer ask for up to 1000 events per request, " <>
                    "and `min_demand: 500`. For most workloads that's a bursty pattern that defeats the point of " <>
                    "GenStage: the consumer either sits idle then gets slammed with 1000 events to process, or " <>
                    "the producer is forced to materialize 1000-element batches at a time. Tuning these is the " <>
                    "main way you express backpressure shape.",
                alternatives: [
                  Fix.new(
                    summary: "Pass max_demand/min_demand on each subscription",
                    detail:
                      "Replace bare module references with `{Producer, max_demand: N, min_demand: M}` and " <>
                        "pick N/M based on the work cost and parallelism you want. As a starting point: " <>
                        "max_demand: 10, min_demand: 5 for moderately heavy events.",
                    example: """
                    ```elixir
                    def init(_) do
                      {:consumer, %{}, subscribe_to: [{Producer, max_demand: 10, min_demand: 5}]}
                    end
                    ```
                    """,
                    applies_when: "Always — explicit demand is the right default for GenStage."
                  )
                ],
                references: ["ARCHITECTURE_RULES.md#5.35"],
                context: %{producer_count: length(untuned)},
                file: file,
                line: line
              )
            ]
        end

      _ ->
        []
    end
  end

  defp extract_list(list) when is_list(list), do: list
  defp extract_list({:__block__, _, [list]}) when is_list(list), do: list
  defp extract_list(_), do: nil

  # A subscription entry has max_demand if it's a tuple with a keyword list
  # containing :max_demand.
  defp has_max_demand?({_producer, opts}) when is_list(opts) do
    Enum.any?(opts, fn
      {:max_demand, _} -> true
      {{:__block__, _, [:max_demand]}, _} -> true
      _ -> false
    end)
  end

  defp has_max_demand?({:{}, _, [_producer, opts]}) when is_list(opts) do
    has_max_demand?({nil, opts})
  end

  defp has_max_demand?(_), do: false

  defp genstage_module?(ast) do
    AST.contains?(ast, fn
      {:use, _, [{:__aliases__, _, [:GenStage]} | _]} -> true
      _ -> false
    end)
  end
end
