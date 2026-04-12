defmodule Archdo.Rules.OTP.SyncCallChains do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.18"

  @impl true
  def description, do: "No synchronous GenServer.call chains from within callbacks"

  @impl true
  def analyze(file, ast, _opts) do
    if not AST.genserver_module?(ast) do
      []
    else
      callbacks = AST.extract_callbacks(ast)

      [:handle_call, :handle_cast, :handle_info]
      |> Enum.flat_map(fn cb_name ->
        (callbacks[cb_name] || [])
        |> Enum.flat_map(fn {_meta, _args, body} ->
          find_genserver_calls_in_callback(file, body, cb_name)
        end)
      end)
    end
  end

  defp find_genserver_calls_in_callback(_file, nil, _cb_name), do: []

  defp find_genserver_calls_in_callback(file, body, cb_name) do
    AST.find_all(body, fn
      {{:., _, [{:__aliases__, _, [:GenServer]}, :call]}, _meta, _args} -> true
      _ -> false
    end)
    |> Enum.map(fn {_, meta, args} ->
      target =
        case args do
          [{:__aliases__, _, parts} | _] -> Enum.join(parts, ".")
          _ -> "another GenServer"
        end

      Diagnostic.warning("5.18",
        title: "Synchronous GenServer call inside a callback",
        message: "#{cb_name} calls GenServer.call(#{target}, ...) while holding the GenServer's loop",
        why:
          "If A's callback waits for B and B (or anything downstream of B) ever calls back into A, the chain " <>
            "deadlocks: A is blocked inside its own callback, so it can't service B's reply. Even non-cyclic " <>
            "chains cascade timeouts — every hop adds 5s of waste before the whole stack times out together. " <>
            "The risk grows with chain depth and is invisible until production load triggers the cycle.",
        alternatives: [
          Fix.new(
            summary: "Gather the data from #{target} before entering the callback",
            detail:
              "Call #{target} from the public API function before invoking GenServer.call on this server, so " <>
                "the slow operation runs on the caller's process. The callback only operates on data already " <>
                "in hand and never blocks waiting on another GenServer.",
            applies_when: "The data can be fetched on the caller side."
          ),
          Fix.new(
            summary: "Use Task.async + handle_info reply pattern for the downstream call",
            detail:
              "Spawn the call to #{target} in a Task, return `{:noreply, state}` immediately, and reply to the " <>
                "original caller from `handle_info({ref, result}, state)`. The GenServer keeps processing other " <>
                "messages while the Task waits.",
            applies_when: "The work is async-friendly and the original caller can wait on a delayed reply."
          ),
          Fix.new(
            summary: "Decouple via PubSub or events",
            detail:
              "Replace the synchronous call with a published event (Phoenix.PubSub, Commanded events, telemetry) " <>
                "that #{target} subscribes to. Neither side blocks the other and the dependency direction becomes explicit.",
            applies_when: "The two GenServers don't need a synchronous reply at all."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#5.18"],
        context: %{target: target, callback: cb_name},
        file: file,
        line: AST.line(meta)
      )
    end)
  end
end
