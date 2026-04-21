defmodule Archdo.Rules.OTP.ReceiveInCallback do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.11"

  @impl true
  def description, do: "No receive inside GenServer callbacks"

  @genserver_callbacks [:handle_call, :handle_cast, :handle_info, :handle_continue, :init]

  @impl true
  def analyze(file, ast, _opts) do
    case AST.genserver_module?(ast) do
      false ->
        []
      true ->
      callbacks = AST.extract_callbacks(ast)

      Enum.flat_map(@genserver_callbacks, fn cb_name ->
        Enum.flat_map(callbacks[cb_name] || [], fn {_meta, _args, body} ->
          find_receives(file, body, cb_name)
        end)
      end)
    end
  end

  defp find_receives(_file, nil, _cb_name), do: []

  defp find_receives(file, body, cb_name) do
    Enum.map(AST.find_all(body, fn
      {:receive, _meta, _} -> true
      _ -> false
    end), fn {:receive, meta, _} ->
      Diagnostic.error("5.11",
        title: "receive inside GenServer callback",
        message: "A receive block appears inside #{cb_name}",
        why:
          "GenServer's behaviour delivers messages through its own selective receive loop using internal " <>
            "tags like :\"$gen_call\" and :\"$gen_cast\". A user-written `receive` consumes those internal " <>
            "messages and corrupts the state machine — replies vanish, callers time out, and system messages " <>
            "stop being handled. Official docs are explicit: never call receive inside a GenServer callback.",
        alternatives: [
          Fix.new(
            summary: "Use handle_info to receive the asynchronous reply",
            detail:
              "Send the request from the callback (or schedule the work elsewhere), return `{:noreply, state}`, " <>
                "and add a `handle_info/2` clause that pattern-matches the reply message. The GenServer keeps " <>
                "its message loop intact and your data still arrives via a normal callback.",
            applies_when: "You need to wait for a message that another process will send."
          ),
          Fix.new(
            summary: "Use Task.async/Task.await outside the GenServer",
            detail:
              "If the work is request/response with one external service, run it in a Task spawned from the " <>
                "callback (`Task.Supervisor.async_nolink/2`) and reply asynchronously via handle_info. The " <>
                "GenServer never blocks on receive itself.",
            applies_when: "You only need a one-shot wait for one external operation."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#5.11"],
        context: %{callback: cb_name},
        file: file,
        line: AST.line(meta)
      )
    end)
  end
end
