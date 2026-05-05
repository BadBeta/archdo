defmodule Archdo.Rules.Boundary.MissingTelemetryHttpAdapter do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "4.22"

  @impl true
  def description,
    do: "Module with 5+ HTTP calls and no telemetry — adapter has no operational visibility"

  @http_modules [[:Req], [:Tesla], [:Finch], [:HTTPoison], [:Mint, :HTTP]]
  @threshold 5

  @impl true
  def analyze(file, ast, _opts) do
    cond do
      AST.test_file?(file) -> []
      AST.has_marker?(ast, :archdo_no_observability) -> []
      AST.contains_telemetry?(ast) or AST.contains_logger?(ast) -> []
      count_http_calls(ast) < @threshold -> []
      true -> [build_diagnostic(file, count_http_calls(ast))]
    end
  end

  defp count_http_calls(ast) do
    {_, count} =
      Macro.prewalk(ast, 0, fn
        {{:., _, [{:__aliases__, _, mod_parts}, _func]}, _meta, _args} = node, acc ->
          case mod_parts in @http_modules do
            true -> {node, acc + 1}
            false -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    count
  end

  defp build_diagnostic(file, n_calls) do
    Diagnostic.info("4.22",
      title: "HTTP adapter without telemetry",
      message:
        "This module makes #{n_calls} HTTP calls (Req / Tesla / Finch / HTTPoison / Mint) " <>
          "but emits no telemetry or Logger — adapter activity is invisible to operators.",
      why:
        "External HTTP boundaries are where production failures concentrate: provider " <>
          "outages, rate limits, slow responses, and timeouts. An adapter without " <>
          "observability turns provider problems into mysterious production-side latency " <>
          "that takes hours to diagnose.",
      alternatives: [
        Fix.new(
          summary: "Wrap each HTTP call in :telemetry.span",
          detail:
            ":telemetry.span([:my_app, :stripe, :get_charge], %{}, fn -> " <>
              "{Req.get(url), %{}} end). Adapters benefit hugely from per-call timing and " <>
              "result classification — the data drives capacity planning and SLO alerting.",
          applies_when: "Always for production HTTP adapters."
        )
      ],
      references: ["GUIDE.md#4.22"],
      context: %{http_call_count: n_calls},
      file: file,
      line: 1
    )
  end
end
