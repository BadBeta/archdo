defmodule Archdo.Rules.Module.CrossCuttingInDomain do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — operational/web/adapter layer carve-out
  # via Archdo.Phoenix.classify_file. Mix tasks, web, controllers,
  # adapters legitimately wrap cross-cutting concerns; flagging
  # Logger noise there is a false positive.

  alias Archdo.{AST, Diagnostic, Fix, Phoenix}

  @max_logger_calls 3

  # Phoenix layers where cross-cutting Logger noise is APPROPRIATE,
  # not a domain pollution. Operational = Mix tasks/release scripts.
  # Web/controller/live_view/router/component = the boundary that
  # emits request-lifecycle logs. Test = the test framework itself.
  @cross_cutting_layers ~w(
    operational test application_root web controller live_view router
    component infrastructure migration
  )a

  @impl true
  def id, do: "1.6"

  @impl true
  def description,
    do: "Cross-cutting concerns (Logger, Telemetry) belong at boundaries, not in domain"

  @impl true
  def analyze(file, ast, opts) do
    classification =
      case Keyword.get(opts, :phoenix) do
        %{layer: _} = c -> c
        _ -> Phoenix.classify_file(file, ast)
      end

    cond do
      classification.layer in @cross_cutting_layers -> []
      AST.test_file?(file) -> []
      adapter_file?(file) -> []
      true -> check_excessive_logging(file, ast)
    end
  end

  defp check_excessive_logging(file, ast) do
    logger_calls = count_logger_calls(ast)

    if logger_calls > @max_logger_calls do
      module_name = AST.extract_module_name(ast)

      [
        Diagnostic.info("1.6",
          title: "Cross-cutting concern in domain",
          message: "Domain module #{module_name} contains #{logger_calls} Logger calls",
          why:
            "Logging is a cross-cutting infrastructure concern. When the domain layer is full of Logger calls, " <>
              "it depends on Logger's runtime, can't be tested in isolation, and the log format becomes coupled " <>
              "to the business code. Cross-cutting concerns belong at the boundaries (adapters, middleware) where " <>
              "they can be turned on/off and reformatted without touching business logic.",
          alternatives: [
            Fix.new(
              summary: "Emit Telemetry events from the domain instead of logging",
              detail:
                "Replace `Logger.info/warning` with `:telemetry.execute([:my_app, :event], measurements, metadata)`. " <>
                  "Subscribe to those events from a Telemetry handler at the boundary and decide there whether to " <>
                  "log them, ship them as metrics, or both. The domain is silent and the observability layer is configurable.",
              applies_when: "The events represent business facts worth observing."
            ),
            Fix.new(
              summary: "Move the logging into the calling adapter/controller",
              detail:
                "If the logs are about request lifecycle or external service calls, the right place is the " <>
                  "adapter or controller that already lives in the outer layer. Have the domain return rich " <>
                  "errors and let the boundary log them.",
              applies_when: "The logs describe interactions with the outside world."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#1.6"],
          context: %{module: module_name, logger_calls: logger_calls},
          file: file,
          line: 1
        )
      ]
    else
      []
    end
  end

  defp count_logger_calls(ast) do
    length(
      AST.find_all(ast, fn
        {{:., _, [{:__aliases__, _, [:Logger]}, level]}, _, _}
        when level in [:debug, :info, :warning, :warn, :notice] ->
          true

        _ ->
          false
      end)
    )
  end

  # adapter detection retained — Phoenix.classify_file/2 doesn't have
  # a generic ":adapter" layer, so explicit substring/suffix check.
  defp adapter_file?(file) do
    String.contains?(file, "/adapter") or
      String.contains?(file, "/adapters/") or
      String.contains?(file, "/clients/") or
      String.ends_with?(file, "_client.ex") or
      String.ends_with?(file, "_adapter.ex")
  end
end
