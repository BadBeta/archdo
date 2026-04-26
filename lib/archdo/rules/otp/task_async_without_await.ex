defmodule Archdo.Rules.OTP.TaskAsyncWithoutAwait do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.22"

  @impl true
  def description, do: "Task.async must be paired with Task.await"

  @impl true
  def analyze(file, ast, _opts) do
    fns = AST.extract_functions(ast)

    Enum.flat_map(fns, fn {_name, _arity, _meta, _args, body} ->
      check_function_body(file, body)
    end)
  end

  defp check_function_body(_file, nil), do: []

  defp check_function_body(file, body) do
    has_async? =
      AST.contains?(body, fn
        {{:., _, [{:__aliases__, _, [:Task]}, :async]}, _, _} -> true
        _ -> false
      end)

    has_await? =
      AST.contains?(body, fn
        {{:., _, [{:__aliases__, _, [:Task]}, func]}, _, _}
        when func in [:await, :await_many, :yield, :yield_many] ->
          true

        _ ->
          false
      end)

    if has_async? and not has_await? do
      # Find the async calls for line numbers
      Enum.map(
        AST.find_all(body, fn
          {{:., _, [{:__aliases__, _, [:Task]}, :async]}, _, _} -> true
          _ -> false
        end),
        fn {_, meta, _} ->
          Diagnostic.warning("5.22",
            title: "Task.async without Task.await",
            message: "Task.async is called but the function never awaits/yields the result",
            why:
              "Task.async is a contract: 'I will await this'. The task is linked to the caller and posts its " <>
                "result back as a message; if you don't await, the reply piles up in the caller's mailbox forever " <>
                "and the link still propagates crashes. Official docs are explicit: 'If you are using async " <>
                "tasks, you must await a reply as they are always sent.'",
            alternatives: [
              Fix.new(
                summary: "Add a Task.await (or Task.yield) call for the async result",
                detail:
                  "If you actually need the result, store the task reference and await it. The pair " <>
                    "Task.async/Task.await is the canonical 'do this in parallel and join later' pattern.",
                example: """
                ```elixir
                task = Task.async(fn -> heavy_work() end)
                other_work()
                result = Task.await(task, 30_000)
                ```
                """,
                applies_when: "You need the task's return value back."
              ),
              Fix.new(
                summary: "Use Task.Supervisor.start_child for fire-and-forget work",
                detail:
                  "If you don't need the result, start the work via `Task.Supervisor.start_child(MyApp.TaskSupervisor, " <>
                    "fn -> ... end)`. There's no link, no reply message, and the supervisor logs crashes.",
                applies_when: "You don't need the result back."
              )
            ],
            references: ["ARCHITECTURE_RULES.md#5.22"],
            context: %{},
            file: file,
            line: AST.line(meta)
          )
        end
      )
    else
      []
    end
  end
end
