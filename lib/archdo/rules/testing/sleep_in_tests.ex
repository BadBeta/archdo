defmodule Archdo.Rules.Testing.SleepInTests do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "7.5"

  @impl true
  def description, do: "No Process.sleep in tests — leads to flaky/slow tests"

  @impl true
  def analyze(file, ast, _opts) do
    if not AST.test_file?(file) do
      []
    else
      find_sleeps(file, ast)
    end
  end

  defp find_sleeps(file, ast) do
    AST.find_all(ast, fn
      {{:., _, [{:__aliases__, _, [:Process]}, :sleep]}, _, _} -> true
      {{:., _, [:timer, :sleep]}, _, _} -> true
      _ -> false
    end)
    |> Enum.map(fn {_, meta, _} ->
      Diagnostic.warning("7.5",
        title: "Sleep in test code",
        message: "Process.sleep / :timer.sleep is used inside a test",
        why:
          "Sleep in tests is a guess at how long an asynchronous operation takes. Set the value too low and " <>
            "the test fails on a slow CI; set it high enough to never fail and the entire suite slows down. " <>
            "Either way you're trading correctness for execution time. ExUnit has explicit synchronization " <>
            "primitives that wait exactly as long as needed and no longer.",
        alternatives: [
          Fix.new(
            summary: "Use `assert_receive/2` to wait for an expected message",
            detail:
              "If the code under test sends a message when it's done, replace the sleep with `assert_receive " <>
                "<pattern>, timeout`. The test wakes up the moment the message arrives and times out if it " <>
                "doesn't, with a clear failure.",
            applies_when: "The async operation sends a message when done."
          ),
          Fix.new(
            summary: "Monitor the process and assert on `:DOWN`",
            detail:
              "If you're waiting for a process to finish, use `ref = Process.monitor(pid)` then " <>
                "`assert_receive {:DOWN, ^ref, :process, _, _}, timeout`. Same idea, no polling.",
            applies_when: "You're waiting for a process to terminate."
          ),
          Fix.new(
            summary: "Use `Task.await/2` for parallel work",
            detail:
              "If the operation is a Task, capture the Task struct and call `Task.await(task, timeout)`. " <>
                "It blocks exactly until the result is ready.",
            applies_when: "The work runs in a Task."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#7.5"],
        context: %{},
        file: file,
        line: AST.line(meta)
      )
    end)
  end

end
