defmodule Archdo.Rules.OTP.MissingTelemetryLiveViewMount do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.AST.Unwrap

  @impl true
  def id, do: "5.58"

  @impl true
  def description, do: "LiveView mount/3 without telemetry — page-load events untracked"

  @impl true
  def analyze(file, ast, _opts) do
    cond do
      AST.test_file?(file) -> []
      AST.has_marker?(ast, :archdo_no_observability) -> []
      not live_view_module?(file, ast) -> []
      true -> check_mount(file, ast)
    end
  end

  defp live_view_module?(file, ast) do
    AST.live_view_file?(file) or AST.uses_live_view?(ast)
  end

  defp check_mount(file, ast) do
    bodies = mount_bodies(ast)

    case bodies do
      [] -> []
      _ -> maybe_flag(file, bodies)
    end
  end

  defp maybe_flag(file, bodies) do
    case Enum.any?(bodies, fn body ->
           AST.contains_telemetry?(body) or AST.contains_logger?(body)
         end) do
      true -> []
      false -> [build_diagnostic(file)]
    end
  end

  defp mount_bodies(ast) do
    {_, bodies} =
      Macro.prewalk(ast, [], fn
        {:def, _, [{:mount, _, args}, kw]} = node, acc
        when is_list(args) and length(args) == 3 and is_list(kw) ->
          case Unwrap.kw_get(kw, :do) do
            {:ok, body} -> {node, [body | acc]}
            :error -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(bodies)
  end

  defp build_diagnostic(file) do
    Diagnostic.info("5.58",
      title: "LiveView mount/3 without telemetry",
      message:
        "This LiveView's `mount/3` body emits no telemetry or Logger calls — page-load " <>
          "timing and entry events are untracked.",
      why:
        "LiveView mount is the equivalent of a page render in a controller-based app. " <>
          "Without telemetry, you can't measure mount latency, see which pages users land " <>
          "on, or correlate mount failures with backend issues. The Phoenix telemetry " <>
          "ecosystem expects mount events at this boundary.",
      alternatives: [
        Fix.new(
          summary: "Emit a mount event with :telemetry.execute",
          detail:
            ":telemetry.execute([:my_app, :live_view, :mount], %{system_time: " <>
              "System.system_time()}, %{view: __MODULE__}). Lightweight, structured, picked " <>
              "up by every Phoenix telemetry handler.",
          applies_when: "Always for production LiveView pages."
        ),
        Fix.new(
          summary: "Wrap mount setup in :telemetry.span if it does notable work",
          detail:
            ":telemetry.span([:my_app, :live_view, :mount], %{}, fn -> " <>
              "{do_mount(params, session, socket), %{}} end). Captures mount duration as " <>
              "a span event.",
          applies_when: "When mount loads data or does heavier setup."
        )
      ],
      references: ["GUIDE.md#5.58"],
      context: %{},
      file: file,
      line: 1
    )
  end
end
