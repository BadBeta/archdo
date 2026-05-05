defmodule Archdo.Rules.OTP.BlockingCallback do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.9"

  @impl true
  def description, do: "No blocking operations in GenServer or Plug callbacks"

  @blocking_modules [[:HTTPoison], [:Finch], [:Req], [:Tesla], [:Mint, :HTTP]]
  @blocking_funcs [{[:File], [:read!, :write!, :read, :write]}, {[:Process], [:sleep]}]

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> genserver_diagnostics(file, ast) ++ plug_diagnostics(file, ast)
    end
  end

  defp genserver_diagnostics(file, ast),
    do: blocking_for_genserver(AST.genserver_module?(ast), file, ast)

  # §§ elixir-implementing: §2.1 — boolean → multi-clause head
  defp blocking_for_genserver(false, _file, _ast), do: []

  defp blocking_for_genserver(true, file, ast) do
    callbacks = AST.extract_callbacks(ast)

    Enum.flat_map(
      [:handle_call, :handle_cast, :handle_info],
      &check_callback_kind(&1, callbacks, file)
    )
  end

  # M17 — Plug call/2 extension. CE-34 (VolatileCallNoTimeout) owns
  # timeout-less HTTP detection in plugs, so we deliberately exclude
  # @blocking_modules here to avoid double-flagging the same call.
  # We focus on Process.sleep, File.* sync ops, and heavy Repo reads
  # in plug call/2 — gaps CE-34 doesn't cover.
  defp plug_diagnostics(file, ast) do
    case plug_module?(file, ast) do
      false -> []
      true -> check_plug_call(file, ast)
    end
  end

  defp plug_module?(file, ast) do
    plug_file?(file) or plug_use_form?(ast) or plug_behaviour?(ast)
  end

  defp plug_file?(file), do: String.contains?(file, "/plugs/")

  defp plug_use_form?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {:use, _, [{:__aliases__, _, parts} | _]} = node, _acc ->
          {node, parts == [:Plug, :Builder] or parts == [:Plug, :Router]}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp plug_behaviour?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {:@, _, [{:behaviour, _, [{:__aliases__, _, parts}]}]} = node, _acc ->
          {node, parts == [:Plug]}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp check_plug_call(file, ast) do
    {_, bodies} =
      Macro.prewalk(ast, [], fn
        {:def, _, [{:call, _, args}, [{:do, body} | _]]} = node, acc
        when is_list(args) and length(args) == 2 ->
          {node, [body | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.flat_map(bodies, &check_plug_body(file, &1))
  end

  defp check_plug_body(file, body) do
    blocking_calls = find_blocking_func_calls(body)
    repo_calls = find_heavy_repo_calls(body)
    sleep_calls = find_sleep_calls(body)

    Enum.map(blocking_calls ++ repo_calls ++ sleep_calls, fn {desc, line} ->
      Diagnostic.warning("5.9",
        title: "Blocking work inside Plug call/2",
        message: "#{desc} runs inside Plug.call/2",
        why:
          "A plug runs inside the request-handling process. Blocking calls in `call/2` " <>
            "occupy that process for the full duration of the slow operation, reducing " <>
            "throughput linearly with concurrency. Move the work off the request path " <>
            "(async Task, background job) or shorten it (timeout, cache).",
        alternatives: [
          Fix.new(
            summary: "Move the slow operation to an async Task or background job",
            detail:
              "If the response doesn't depend on the result, dispatch the work via " <>
                "`Task.Supervisor.start_child/2` or queue it via Oban. The plug returns " <>
                "immediately and the heavy work runs out-of-band.",
            applies_when: "When the response is independent of the slow call's result."
          ),
          Fix.new(
            summary: "Apply a tight timeout and bound the wait",
            detail:
              "If the response DOES depend on the result, ensure the call has an explicit " <>
                "timeout. CE-34 covers the HTTP-without-timeout case; for sync I/O, switch " <>
                "to async equivalents or use `Task.await/2` with a bounded timeout.",
            applies_when: "When the response needs the result but waiting forever is wrong."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#5.9"],
        context: %{call: desc, callback: :"Plug.call/2"},
        file: file,
        line: line
      )
    end)
  end

  defp check_callback_kind(cb_name, callbacks, file) do
    Enum.flat_map(callbacks[cb_name] || [], fn {_meta, _args, body} ->
      check_body(file, body, cb_name)
    end)
  end

  defp check_body(_file, nil, _cb_name), do: []

  defp check_body(file, body, cb_name) do
    http_calls = find_http_calls(body)
    blocking_calls = find_blocking_func_calls(body)
    repo_calls = find_heavy_repo_calls(body)
    sleep_calls = find_sleep_calls(body)

    Enum.map(http_calls ++ blocking_calls ++ repo_calls ++ sleep_calls, fn {desc, line} ->
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
    Enum.map(
      AST.find_all(body, fn
        {{:., _, [{:__aliases__, _, mod_parts}, _func]}, _meta, _args} ->
          mod_parts in @blocking_modules

        _ ->
          false
      end),
      fn {{:., _, [{:__aliases__, _, mod_parts}, func]}, meta, _} ->
        {"#{Enum.join(mod_parts, ".")}.#{func}", AST.line(meta)}
      end
    )
  end

  defp find_blocking_func_calls(body) do
    Enum.map(
      AST.find_all(body, fn
        {{:., _, [{:__aliases__, _, mod_parts}, func]}, _meta, _args} ->
          Enum.any?(@blocking_funcs, fn {mod, funcs} ->
            mod_parts == mod and func in funcs
          end)

        _ ->
          false
      end),
      fn {{:., _, [{:__aliases__, _, mod_parts}, func]}, meta, _} ->
        {"#{Enum.join(mod_parts, ".")}.#{func}", AST.line(meta)}
      end
    )
  end

  defp find_heavy_repo_calls(body) do
    Enum.map(
      AST.find_all(body, fn
        {{:., _, [{:__aliases__, _, mod_parts}, func]}, _meta, _args} ->
          List.last(mod_parts) == AST.repo_atom() and func in [:all, :stream, :aggregate]

        _ ->
          false
      end),
      fn {{:., _, [{:__aliases__, _, mod_parts}, func]}, meta, _} ->
        {"#{Module.concat(mod_parts)}.#{func} (potentially large result)", AST.line(meta)}
      end
    )
  end

  defp find_sleep_calls(body) do
    Enum.map(
      AST.find_all(body, fn
        {{:., _, [{:__aliases__, _, [:Process]}, :sleep]}, _, _} -> true
        {{:., _, [:timer, :sleep]}, _, _} -> true
        _ -> false
      end),
      fn
        {{:., _, [{:__aliases__, _, [:Process]}, :sleep]}, meta, _} ->
          {"Process.sleep", AST.line(meta)}

        {{:., _, [:timer, :sleep]}, meta, _} ->
          {":timer.sleep", AST.line(meta)}
      end
    )
  end
end
