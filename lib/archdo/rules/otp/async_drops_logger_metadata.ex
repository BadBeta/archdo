defmodule Archdo.Rules.OTP.AsyncDropsLoggerMetadata do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.55"

  @impl true
  def description,
    do:
      "Async work logs / emits telemetry without propagating Logger.metadata — trace context lost"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_async_metadata_drops(file, ast)
    end
  end

  defp find_async_metadata_drops(file, ast) do
    {_, hits} =
      Macro.prewalk(ast, [], fn node, acc -> collect(node, acc, file) end)

    Enum.reverse(hits)
  end

  # §§ elixir-implementing: §5.2 — multi-clause head dispatch on the async-
  # entry-point AST shape. Each clause matches one entry point and extracts
  # its closure argument.

  # Task.Supervisor.start_child(sup, fn -> ... end)
  defp collect(
         {{:., _, [{:__aliases__, _, [:Task, :Supervisor]}, :start_child]}, meta, args} = node,
         acc,
         file
       ) do
    {node, classify_async(args, meta, file, acc, "Task.Supervisor.start_child")}
  end

  # Task.async(fn -> ... end)
  defp collect(
         {{:., _, [{:__aliases__, _, [:Task]}, :async]}, meta, args} = node,
         acc,
         file
       ) do
    {node, classify_async(args, meta, file, acc, "Task.async")}
  end

  # Task.async_stream(coll, fn -> ... end)  — closure is 2nd or 3rd arg
  defp collect(
         {{:., _, [{:__aliases__, _, [:Task]}, :async_stream]}, meta, args} = node,
         acc,
         file
       ) do
    {node, classify_async(args, meta, file, acc, "Task.async_stream")}
  end

  # Task.Supervisor.async_nolink — same shape
  defp collect(
         {{:., _, [{:__aliases__, _, [:Task, :Supervisor]}, :async_nolink]}, meta, args} =
           node,
         acc,
         file
       ) do
    {node, classify_async(args, meta, file, acc, "Task.Supervisor.async_nolink")}
  end

  defp collect(node, acc, _file), do: {node, acc}

  # `args` is the call's argument list. Find the closure within it (if any),
  # then check the closure body.
  defp classify_async(args, meta, file, acc, primitive) do
    case find_closure(args) do
      nil -> acc
      closure -> classify_closure(closure, meta, file, acc, primitive)
    end
  end

  defp classify_closure(closure, meta, file, acc, primitive) do
    body = closure_body(closure)

    case logs_or_emits_telemetry?(body) and not propagates_metadata?(body) do
      true -> [build_diagnostic(file, meta, primitive) | acc]
      false -> acc
    end
  end

  defp find_closure(args) when is_list(args) do
    Enum.find(args, fn
      {:fn, _, _} -> true
      _ -> false
    end)
  end

  defp closure_body({:fn, _, [{:->, _, [_args, body]}]}), do: body
  defp closure_body(_), do: nil

  # The closure logs if its body contains Logger.<level>(...) or
  # :telemetry.execute(...).
  defp logs_or_emits_telemetry?(nil), do: false

  defp logs_or_emits_telemetry?(body) do
    AST.contains?(body, fn
      {{:., _, [{:__aliases__, _, [:Logger]}, level]}, _, _}
      when level in [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency] ->
        true

      {{:., _, [:telemetry, :execute]}, _, _} ->
        true

      _ ->
        false
    end)
  end

  defp propagates_metadata?(nil), do: false

  defp propagates_metadata?(body) do
    AST.contains?(body, fn
      {{:., _, [{:__aliases__, _, [:Logger]}, :metadata]}, _, _} -> true
      _ -> false
    end)
  end

  defp build_diagnostic(file, meta, primitive) do
    Diagnostic.warning("5.55",
      title: "Async closure logs without restoring Logger.metadata",
      message:
        "#{primitive} runs a closure that calls Logger or :telemetry.execute, " <>
          "but does not call Logger.metadata/1 inside the closure. The spawned " <>
          "process starts with empty metadata — the parent's trace_id, request_id, " <>
          "and tenant_id are missing from any log/metric the task emits.",
      why:
        "Logger.metadata is per-process. A spawned task starts with empty " <>
          "metadata, so any log line or telemetry it emits is missing the " <>
          "request's correlation context. Async logs become orphaned — when an " <>
          "operator searches for `trace_id=abc123`, the async work is invisible.",
      alternatives: [
        Fix.new(
          summary: "Capture parent metadata; restore inside the closure",
          detail:
            "Read it on the calling side (`metadata = Logger.metadata()`) and " <>
              "restore inside the closure (`Logger.metadata(metadata)`). The " <>
              "spawned task's logs/telemetry now carry the parent's correlation " <>
              "IDs.",
          applies_when: "The caller has Logger.metadata set (request scope)."
        ),
        Fix.new(
          summary: "Pass an explicit context struct into the closure",
          detail:
            "Build `%TraceContext{trace_id: ..., tenant_ref: ...}` at the entry " <>
              "and pass it into the closure. The closure includes it in every " <>
              "log/telemetry call: `Logger.info(\"work\", trace_id: ctx.trace_id)`. " <>
              "More verbose than Logger.metadata but immune to per-process scope.",
          applies_when: "The trace context is the explicit parameter shape used elsewhere."
        )
      ],
      tags: [:observability],
      file: file,
      line: AST.line(meta)
    )
  end
end
