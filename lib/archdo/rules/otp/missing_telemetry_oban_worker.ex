defmodule Archdo.Rules.OTP.MissingTelemetryObanWorker do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.AST.Unwrap

  @impl true
  def id, do: "5.56"

  @impl true
  def description,
    do: "Oban worker `perform/1` body emits no telemetry — runtime is invisible"

  @impl true
  def analyze(file, ast, _opts) do
    cond do
      AST.test_file?(file) -> []
      AST.has_marker?(ast, :archdo_no_observability) -> []
      not oban_worker?(ast) -> []
      true -> check_perform(file, ast)
    end
  end

  defp oban_worker?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {:use, _, [{:__aliases__, _, mod_parts} | _]} = node, _acc ->
          {node, oban_worker_alias?(mod_parts)}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp oban_worker_alias?(parts) do
    parts == [:Oban, :Worker] or List.last(parts) == :Worker
  end

  defp check_perform(file, ast) do
    case extract_perform_clauses(ast) do
      [] -> []
      clauses -> maybe_flag(clauses, file)
    end
  end

  defp maybe_flag(clauses, file) do
    case Enum.any?(clauses, fn {_meta, body} ->
           AST.contains_telemetry?(body) or AST.contains_logger?(body)
         end) do
      true -> []
      false -> [build_diagnostic(file, hd(clauses) |> elem(0) |> AST.line())]
    end
  end

  # Extract every `def perform(arg), do: body` clause as `{meta, body}`.
  # Arity-1 `perform/1` is the `Oban.Worker` callback. Handles both
  # raw-keyword AST (`Code.string_to_quoted`) and literal-encoder
  # wrapping (`AST.parse_files`) where `:do` is wrapped in a
  # `{:__block__, _, [:do]}` envelope.
  defp extract_perform_clauses(ast) do
    {_, clauses} =
      Macro.prewalk(ast, [], fn
        {:def, meta, [{:perform, _, args}, kw]} = node, acc
        when is_list(args) and length(args) == 1 and is_list(kw) ->
          {node, maybe_collect_perform(meta, kw, acc)}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(clauses)
  end

  defp maybe_collect_perform(meta, kw, acc) do
    case do_body_from_kw(kw) do
      {:ok, body} -> [{meta, body} | acc]
      :error -> acc
    end
  end

  defp do_body_from_kw([]), do: :error

  defp do_body_from_kw([{key, val} | rest]) do
    case Unwrap.try_atom(key) do
      :do -> {:ok, val}
      _ -> do_body_from_kw(rest)
    end
  end

  defp do_body_from_kw([_ | rest]), do: do_body_from_kw(rest)

  defp build_diagnostic(file, line) do
    Diagnostic.info("5.56",
      title: "Oban worker without observability in perform/1",
      message:
        "This module is an Oban worker (uses Oban.Worker) but `perform/1` emits no " <>
          "telemetry or Logger calls — its runtime is invisible to operators.",
      why:
        "Oban workers run async and out-of-band. Without telemetry or logging, you " <>
          "can't tell whether a job ran, how long it took, or whether it errored. " <>
          "Observability must be intentional for background work; the request handler " <>
          "isn't there to do it for you.",
      alternatives: [
        Fix.new(
          summary: "Wrap perform/1 in :telemetry.span",
          detail:
            ":telemetry.span([:my_app, :worker, :send_email], %{user_id: id}, fn ->\n" <>
              "  do_perform(args)\n  {:ok, %{}}\nend)",
          applies_when: "Always for Oban workers in production."
        ),
        Fix.new(
          summary: "Add Logger.info at start and on result",
          detail:
            "If telemetry is more than you need, at minimum log the job id and outcome. " <>
              "`Logger.info(\"send_email start\", job_id: job.id)` then log the result.",
          applies_when: "Lightweight or new workers; promote to telemetry when scale grows."
        ),
        Fix.new(
          summary: "Mark @archdo_no_observability if genuinely fire-and-forget",
          detail:
            "If a worker is so trivial that no operator will ever ask about it (cleanup " <>
              "of expired tokens, etc.), set `@archdo_no_observability \"reason\"` at " <>
              "module level. Documents intent and silences this rule.",
          applies_when: "Workers where invisibility is the deliberate, justified choice."
        )
      ],
      references: ["GUIDE.md#5.56"],
      context: %{},
      file: file,
      line: line
    )
  end
end
