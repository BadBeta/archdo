defmodule Archdo.Rules.OTP.EtsAsBus do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.27"

  @impl true
  def description, do: "ETS used as message bus — use message passing instead"

  @impl true
  def analyze(file, ast, _opts) do
    check_ets_polling_pattern(file, ast)
  end

  defp check_ets_polling_pattern(file, ast) do
    has_ets_insert? =
      AST.contains?(ast, fn
        {{:., _, [:ets, :insert]}, _, _} -> true
        _ -> false
      end)

    has_ets_delete? =
      AST.contains?(ast, fn
        # delete with key, not table delete
        {{:., _, [:ets, :delete]}, _, [_, _]} -> true
        _ -> false
      end)

    has_polling? =
      AST.contains?(ast, fn
        {{:., _, [:ets, :first]}, _, _} -> true
        {{:., _, [:ets, :next]}, _, _} -> true
        _ -> false
      end)

    has_sleep_loop? =
      AST.contains?(ast, fn
        {{:., _, [{:__aliases__, _, [:Process]}, :sleep]}, _, _} -> true
        _ -> false
      end)

    if has_ets_insert? and has_ets_delete? and (has_polling? or has_sleep_loop?) do
      [
        Diagnostic.info("5.27",
          title: "ETS used as a message bus",
          message:
            "Module combines :ets.insert + :ets.delete + polling/sleep — ETS is being used as a message queue",
          why:
            "Elixir/Erlang already provide message passing, GenStage for backpressured producer-consumer " <>
              "pipelines, Broadway for data pipelines, and PubSub for fan-out. Reinventing them on top of ETS " <>
              "loses backpressure (the queue fills until OOM), wastes CPU on polling, has no ordering " <>
              "guarantees, and races between concurrent readers.",
          alternatives: [
            Fix.new(
              summary: "Use Phoenix.PubSub or GenServer messaging directly",
              detail:
                "If the data flow is fan-out or one-shot, send messages directly to the consumer process or " <>
                  "publish to a PubSub topic the consumer subscribes to. No polling, automatic ordering per sender.",
              applies_when: "The flow is fan-out or 1-to-1."
            ),
            Fix.new(
              summary: "Use GenStage or Broadway for producer/consumer with backpressure",
              detail:
                "If you actually need a queue with throttling, use GenStage. For data pipelines (Kafka, SQS, " <>
                  "RabbitMQ ingestion), Broadway gives you concurrency, batching, retry, and metrics out of the box.",
              applies_when: "The flow is producer/consumer with rate management."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#5.27"],
          context: %{},
          file: file,
          line: 1
        )
      ]
    else
      []
    end
  end
end
