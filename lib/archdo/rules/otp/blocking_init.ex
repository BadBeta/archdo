defmodule Archdo.Rules.OTP.BlockingInit do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.8"

  @impl true
  def description, do: "No blocking work in GenServer init/1"

  # Known blocking modules and their functions
  @blocking_calls [
    {[:HTTPoison], nil},
    {[:Finch], nil},
    {[:Req], nil},
    {[:Tesla], nil},
    {[:Mint, :HTTP], nil},
    {[:File], :read},
    {[:File], :read!},
    {[:File], :write},
    {[:File], :write!},
    {[:Process], :sleep},
    {:timer, :sleep}
  ]

  @impl true
  def analyze(file, ast, _opts) do
    case AST.genserver_module?(ast) do
      false ->
        []
      true ->
      callbacks = AST.extract_callbacks(ast)

      Enum.flat_map(callbacks[:init], fn {meta, _args, body} ->
        check_init_body(file, body, AST.line(meta))
      end)
    end
  end

  defp check_init_body(_file, nil, _line), do: []

  defp check_init_body(file, body, _default_line) do
    blocking_calls = find_blocking_calls(body)
    repo_calls = find_repo_calls(body)

    Enum.map(blocking_calls ++ repo_calls, fn {call_desc, line} ->
      Diagnostic.warning("5.8",
        title: "Blocking work in GenServer init/1",
        message: "#{call_desc} runs inside init/1",
        why:
          "init/1 runs synchronously while the supervisor waits for the child to start. Every blocking call " <>
            "(HTTP, Repo, File I/O, sleep) delays the entire supervision tree behind it; if the call exceeds " <>
            "the supervisor's start_timeout the supervisor decides the child failed and aborts boot. Per Fred " <>
            "Hebert: only local guarantees belong in init.",
        alternatives: [
          Fix.new(
            summary: "Return `{:continue, ...}` from init/1 and do the work in handle_continue/2",
            detail:
              "init/1 returns immediately with placeholder state, then handle_continue/2 runs as the very next " <>
                "message — guaranteed before any external message — and performs the slow work. The supervisor " <>
                "treats the child as started so the rest of the tree can boot in parallel.",
            example: """
            ```elixir
            def init(args) do
              {:ok, %{data: nil}, {:continue, :load}}
            end

            def handle_continue(:load, state) do
              data = ExternalService.fetch()
              {:noreply, %{state | data: data}}
            end
            ```
            """,
            applies_when: "The work must run before the GenServer starts handling messages."
          ),
          Fix.new(
            summary: "Schedule the work in a separate process and let init/1 return immediately",
            detail:
              "If the data isn't strictly required before serving requests, kick off a Task or send the work " <>
                "to a worker GenServer from init/1 (via Task.Supervisor or `Process.send_after(self(), :load, 0)`).",
            applies_when: "The data is needed eventually but not immediately."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#5.8"],
        context: %{call: call_desc},
        file: file,
        line: line
      )
    end)
  end

  defp find_blocking_calls(body) do
    Enum.map(AST.find_all(body, fn
      {{:., _, [{:__aliases__, _, mod_parts}, func]}, _meta, _args} ->
        Enum.any?(@blocking_calls, fn
          {mod, nil} -> mod_parts == mod
          {mod, f} -> mod_parts == mod and func == f
        end)

      {{:., _, [:timer, :sleep]}, _meta, _args} ->
        true

      _ ->
        false
    end), fn
      {{:., _, [{:__aliases__, _, mod_parts}, func]}, meta, _} ->
        {"#{Enum.join(mod_parts, ".")}.#{func}", AST.line(meta)}

      {{:., _, [:timer, :sleep]}, meta, _} ->
        {":timer.sleep", AST.line(meta)}
    end)
  end

  defp find_repo_calls(body) do
    Enum.map(AST.find_all(body, fn
      {{:., _, [{:__aliases__, _, mod_parts}, _func]}, _meta, _args} ->
        List.last(mod_parts) == :Repo

      _ ->
        false
    end), fn {{:., _, [{:__aliases__, _, mod_parts}, func]}, meta, _} ->
      {"#{Enum.join(mod_parts, ".")}.#{func}", AST.line(meta)}
    end)
  end
end
