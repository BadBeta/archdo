defmodule Archdo.Rules.OTP.BlockingCallback do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.9"

  @impl true
  def description, do: "No blocking operations in GenServer callbacks"

  @blocking_modules [[:HTTPoison], [:Finch], [:Req], [:Tesla], [:Mint, :HTTP]]
  @blocking_funcs [{[:File], [:read!, :write!, :read, :write]}, {[:Process], [:sleep]}]

  @impl true
  def analyze(file, ast, _opts) do
    case AST.genserver_module?(ast) do
      false ->
        []
      true ->
      callbacks = AST.extract_callbacks(ast)

      [:handle_call, :handle_cast, :handle_info]
      |> Enum.flat_map(fn cb_name ->
        (callbacks[cb_name] || [])
        |> Enum.flat_map(fn {_meta, _args, body} ->
          check_body(file, body, cb_name)
        end)
      end)
    end
  end

  defp check_body(_file, nil, _cb_name), do: []

  defp check_body(file, body, cb_name) do
    http_calls = find_http_calls(body)
    blocking_calls = find_blocking_func_calls(body)
    repo_calls = find_heavy_repo_calls(body)
    sleep_calls = find_sleep_calls(body)

    (http_calls ++ blocking_calls ++ repo_calls ++ sleep_calls)
    |> Enum.map(fn {desc, line} ->
      Diagnostic.warning("5.9",
        title: "Blocking work inside GenServer callback",
        message: "#{desc} runs inside #{cb_name}",
        why:
          "A GenServer processes one message at a time. While #{cb_name} blocks on a slow call, every other " <>
            "caller queues up; for handle_call the callers will time out (default 5s). One slow HTTP request " <>
            "or large query is enough to make the entire server unresponsive and the failure mode is a flood " <>
            "of timeouts that look like the GenServer crashed.",
        alternatives: [
          Fix.new(
            summary: "Delegate the work to a supervised Task and reply asynchronously",
            detail:
              "Spawn the slow operation with `Task.Supervisor.async_nolink/2`, return `{:noreply, state}` " <>
                "immediately, and reply to the original caller from `handle_info({ref, result}, state)`. The " <>
                "GenServer keeps processing other messages while the task runs.",
            example: """
            ```elixir
            def handle_call(:fetch, from, state) do
              Task.Supervisor.async_nolink(MyApp.TaskSupervisor, fn ->
                ExternalService.fetch()
              end)
              {:noreply, Map.put(state, :pending_from, from)}
            end

            def handle_info({ref, result}, state) do
              GenServer.reply(state.pending_from, result)
              Process.demonitor(ref, [:flush])
              {:noreply, Map.delete(state, :pending_from)}
            end
            ```
            """,
            applies_when: "The work is genuinely slow and the caller can wait asynchronously."
          ),
          Fix.new(
            summary: "Move the work out of the GenServer entirely",
            detail:
              "If the callback isn't tied to GenServer-managed state, run the call directly on the caller " <>
                "instead of routing through the GenServer. The GenServer should only own work that needs the " <>
                "shared state or serial ordering.",
            applies_when: "The slow call doesn't actually depend on GenServer state."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#5.9"],
        context: %{call: desc, callback: cb_name},
        file: file,
        line: line
      )
    end)
  end

  defp find_http_calls(body) do
    AST.find_all(body, fn
      {{:., _, [{:__aliases__, _, mod_parts}, _func]}, _meta, _args} ->
        mod_parts in @blocking_modules

      _ ->
        false
    end)
    |> Enum.map(fn {{:., _, [{:__aliases__, _, mod_parts}, func]}, meta, _} ->
      {"#{Enum.join(mod_parts, ".")}.#{func}", AST.line(meta)}
    end)
  end

  defp find_blocking_func_calls(body) do
    AST.find_all(body, fn
      {{:., _, [{:__aliases__, _, mod_parts}, func]}, _meta, _args} ->
        Enum.any?(@blocking_funcs, fn {mod, funcs} ->
          mod_parts == mod and func in funcs
        end)

      _ ->
        false
    end)
    |> Enum.map(fn {{:., _, [{:__aliases__, _, mod_parts}, func]}, meta, _} ->
      {"#{Enum.join(mod_parts, ".")}.#{func}", AST.line(meta)}
    end)
  end

  defp find_heavy_repo_calls(body) do
    AST.find_all(body, fn
      {{:., _, [{:__aliases__, _, mod_parts}, func]}, _meta, _args} ->
        List.last(mod_parts) == :Repo and func in [:all, :stream, :aggregate]

      _ ->
        false
    end)
    |> Enum.map(fn {{:., _, [{:__aliases__, _, mod_parts}, func]}, meta, _} ->
      {"#{Module.concat(mod_parts)}.#{func} (potentially large result)", AST.line(meta)}
    end)
  end

  defp find_sleep_calls(body) do
    AST.find_all(body, fn
      {{:., _, [{:__aliases__, _, [:Process]}, :sleep]}, _, _} -> true
      {{:., _, [:timer, :sleep]}, _, _} -> true
      _ -> false
    end)
    |> Enum.map(fn
      {{:., _, [{:__aliases__, _, [:Process]}, :sleep]}, meta, _} ->
        {"Process.sleep", AST.line(meta)}

      {{:., _, [:timer, :sleep]}, meta, _} ->
        {":timer.sleep", AST.line(meta)}
    end)
  end
end
