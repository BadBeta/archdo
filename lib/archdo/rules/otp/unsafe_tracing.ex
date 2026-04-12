defmodule Archdo.Rules.OTP.UnsafeTracing do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.34"

  @impl true
  def description, do: "Unsafe production tracing — :dbg and :erlang.trace have no safety limits"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) or script_file?(file) do
      []
    else
      find_unsafe_tracing(file, ast)
    end
  end

  defp find_unsafe_tracing(file, ast) do
    AST.find_all(ast, fn
      # :dbg.tracer, :dbg.p, :dbg.tp, :dbg.c, etc.
      {{:., _, [:dbg, func]}, _, _}
      when func in [:tracer, :p, :tp, :tpl, :ctp, :ctpl, :c, :stop, :stop_clear] ->
        true

      # :erlang.trace, :erlang.trace_pattern
      {{:., _, [:erlang, func]}, _, _}
      when func in [:trace, :trace_pattern, :trace_info, :trace_delivered] ->
        true

      _ ->
        false
    end)
    |> Enum.map(fn {_, meta, _} = node ->
      {module, func} =
        case node do
          {{:., _, [m, f]}, _, _} -> {m, f}
          _ -> {:unknown, :unknown}
        end

      Diagnostic.warning("5.34",
        title: "Unsafe tracing primitive in production code",
        message: "Direct call to :#{module}.#{func} with no rate or message limits",
        why:
          "`:dbg` and `:erlang.trace` have no built-in safety limits. A trace pattern that matches a hot " <>
            "function can flood the BEAM with billions of trace messages within seconds, exhausting memory or " <>
            "freezing schedulers. They are fine for short interactive sessions but committing them to " <>
            "production code is one of the easiest ways to take down the entire VM.",
        alternatives: [
          Fix.new(
            summary: "Use `:recon_trace.calls/2` with an explicit message limit",
            detail:
              "Recon's tracer enforces a hard upper bound on the number of trace messages and rate-limits " <>
                "delivery. Even if your pattern matches everything, the VM is protected.",
            example: """
            ```elixir
            :recon_trace.calls({Mod, :fun, :return_trace}, 100)
            ```
            """,
            applies_when: "You need to trace function calls in a running system."
          ),
          Fix.new(
            summary: "Move the tracing into a manual ad-hoc IEx session, not committed code",
            detail:
              "If the tracing is for one-off debugging, do it from IEx attached to the running node and don't " <>
                "land it on the main branch. That way it cannot accidentally re-enable itself in production.",
            applies_when: "The trace was added during debugging and was never meant to ship."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#5.34"],
        context: %{module: module, func: func},
        file: file,
        line: AST.line(meta)
      )
    end)
  end

  defp script_file?(file), do: String.ends_with?(file, ".exs") and not AST.test_file?(file)
end
