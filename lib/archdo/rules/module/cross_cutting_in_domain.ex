defmodule Archdo.Rules.Module.CrossCuttingInDomain do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @max_logger_calls 3

  @impl true
  def id, do: "1.6"

  @impl true
  def description, do: "Cross-cutting concerns (Logger, Telemetry) belong at boundaries, not in domain"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) or web_file?(file) or adapter_file?(file) or
         infrastructure_file?(file) do
      []
    else
      check_excessive_logging(file, ast)
    end
  end

  defp check_excessive_logging(file, ast) do
    logger_calls = count_logger_calls(ast)

    if logger_calls > @max_logger_calls do
      module_name = extract_module_name(ast)

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
    AST.find_all(ast, fn
      {{:., _, [{:__aliases__, _, [:Logger]}, level]}, _, _}
      when level in [:debug, :info, :warning, :warn, :notice] ->
        true

      _ ->
        false
    end)
    |> length()
  end

  defp extract_module_name(ast) do
    {_, name} =
      Macro.prewalk(ast, "Unknown", fn
        {:defmodule, _, [{:__aliases__, _, aliases} | _]} = node, _acc ->
          {node, Module.concat(aliases) |> Atom.to_string() |> String.replace_leading("Elixir.", "")}

        node, acc ->
          {node, acc}
      end)

    name
  end

  defp web_file?(file), do: String.contains?(file, "_web/") or String.contains?(file, "web/")

  defp adapter_file?(file) do
    String.contains?(file, "/adapter") or
      String.contains?(file, "/adapters/") or
      String.contains?(file, "/clients/") or
      String.ends_with?(file, "_client.ex") or
      String.ends_with?(file, "_adapter.ex")
  end

  defp infrastructure_file?(file) do
    String.contains?(file, "/infrastructure/") or
      String.ends_with?(file, "/repo.ex") or
      String.ends_with?(file, "/mailer.ex") or
      String.ends_with?(file, "/telemetry.ex") or
      String.ends_with?(file, "/application.ex")
  end
end
