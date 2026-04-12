defmodule Archdo.Rules.OTP.LargeMessages do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.19"

  @impl true
  def description, do: "Don't send entire conn or large structs to other processes"

  @impl true
  def analyze(file, ast, _opts) do
    find_conn_in_spawn(file, ast)
  end

  defp find_conn_in_spawn(file, ast) do
    # Find spawn/Task.async/GenServer.cast/send where conn is an argument
    process_sends = AST.find_all(ast, fn
      {:spawn, _meta, [func]} -> contains_conn_ref?(func)
      {:spawn_link, _meta, [func]} -> contains_conn_ref?(func)
      {:send, _meta, [_, msg]} -> contains_conn_ref?(msg)

      {{:., _, [{:__aliases__, _, [:GenServer]}, func]}, _meta, [_ | args]}
      when func in [:call, :cast] ->
        Enum.any?(args, &contains_conn_ref?/1)

      {{:., _, [{:__aliases__, _, [:Task]}, :async]}, _meta, [func]} ->
        contains_conn_ref?(func)

      {{:., _, [{:__aliases__, _, [:Task, :Supervisor]}, func]}, _meta, [_ | args]}
      when func in [:start_child, :async, :async_nolink] ->
        Enum.any?(args, &contains_conn_ref?/1)

      _ ->
        false
    end)

    process_sends
    |> Enum.map(fn {_, meta, _} ->
      Diagnostic.info("5.19",
        title: "conn sent to another process",
        message: "The Plug.Conn struct is captured/sent to another process",
        why:
          "Erlang has share-nothing semantics: every term sent in a message is fully copied between process " <>
            "heaps. A `conn` carries the request body, params, assigns, private data, and adapter state — " <>
            "potentially several KB per request. Sending it to a Task or GenServer copies all of that for " <>
            "every request and pressures the garbage collector on both sides.",
        alternatives: [
          Fix.new(
            summary: "Extract only the fields you need before sending",
            detail:
              "Pull the specific values out of conn into local variables, then pass those to the spawned " <>
                "function. Only the small primitives are copied and the conn stays on the original process.",
            example: """
            ```elixir
            ip = conn.remote_ip
            path = conn.request_path
            spawn(fn -> log_request(ip, path) end)
            ```
            """,
            applies_when: "You only need a few fields from conn."
          ),
          Fix.new(
            summary: "Stash the data in ETS and send only the key",
            detail:
              "If the receiving process needs a lot of fields, write them once to a public ETS table keyed by " <>
                "request id, then send the id. ETS reads are O(1) and the message itself stays small.",
            applies_when: "The receiver needs many fields and the data is read once."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#5.19"],
        context: %{kind: :conn},
        file: file,
        line: AST.line(meta)
      )
    end)
  end

  defp contains_conn_ref?(ast) do
    AST.contains?(ast, fn
      {:conn, _, nil} -> true
      {:conn, _, context} when is_atom(context) -> true
      _ -> false
    end)
  end
end
