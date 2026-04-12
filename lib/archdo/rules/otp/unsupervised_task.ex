defmodule Archdo.Rules.OTP.UnsupervisedTask do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.23"

  @impl true
  def description, do: "Tasks should use Task.Supervisor"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      find_bare_task_start(file, ast)
    end
  end

  defp find_bare_task_start(file, ast) do
    AST.find_all(ast, fn
      # Task.start/1, Task.start_link/1
      {{:., _, [{:__aliases__, _, [:Task]}, func]}, _meta, _args}
      when func in [:start, :start_link] ->
        true

      _ ->
        false
    end)
    |> Enum.map(fn {{:., _, [{:__aliases__, _, [:Task]}, func]}, meta, _} ->
      Diagnostic.info("5.23",
        title: "Bare Task.#{func} without supervisor",
        message: "Task.#{func}/1 used in production code instead of Task.Supervisor",
        why:
          "Unsupervised Tasks lack visibility, ordered shutdown, and isolation from the caller. Official docs " <>
            "recommend supervised Tasks for production code: they are logged on crash, included in Observer, " <>
            "and the supervisor terminates them cleanly when the application stops. Bare Task.start has none of these.",
        alternatives: [
          Fix.new(
            summary: "Switch to Task.Supervisor.start_child",
            detail:
              "Add `{Task.Supervisor, name: MyApp.TaskSupervisor}` to your supervision tree, then call " <>
                "`Task.Supervisor.start_child(MyApp.TaskSupervisor, fn -> work() end)`. The Task is now " <>
                "supervised, observable, and shutdown-safe.",
            applies_when: "The work is fire-and-forget."
          ),
          Fix.new(
            summary: "Use Task.Supervisor.async_nolink + handle_info for results",
            detail:
              "If you need the result but don't want a crash to propagate, use `async_nolink/2` and reply " <>
                "from a `handle_info({ref, result}, state)` clause. The result is delivered, the caller stays " <>
                "alive on task crashes.",
            applies_when: "You need the result and want isolation from crashes."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#5.23"],
        context: %{call: "Task.#{func}"},
        file: file,
        line: AST.line(meta)
      )
    end)
  end

end
