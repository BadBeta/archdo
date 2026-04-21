defmodule Archdo.Rules.OTP.SpawnWithoutLink do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.21"

  @impl true
  def description, do: "spawn without link or monitor — failures go unnoticed"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      Enum.map(AST.find_all(ast, fn
        {:spawn, _meta, args} when is_list(args) and length(args) in [1, 3] -> true
        _ -> false
      end), fn {:spawn, meta, args} ->
        Diagnostic.warning("5.21",
          title: "Bare spawn without link or monitor",
          message: "spawn/#{length(args)} starts a process the parent neither links nor monitors",
          why:
            "Plain spawn is fire-and-forget-and-pray: if the spawned process crashes, the parent has no idea, " <>
              "no error propagation, no cleanup, and no retry. The work silently fails and no log entry is " <>
              "produced. This is one of the easiest ways to lose work in production with no visibility.",
          alternatives: [
            Fix.new(
              summary: "Use Task.Supervisor.start_child for supervised fire-and-forget",
              detail:
                "Add a Task.Supervisor to the supervision tree (e.g. `{Task.Supervisor, name: MyApp.TaskSupervisor}`) " <>
                  "and start the work via `Task.Supervisor.start_child(MyApp.TaskSupervisor, fn -> ... end)`. " <>
                  "Crashes are logged, the supervisor cleans up on application shutdown, and the task shows up in Observer.",
              applies_when: "The work is fire-and-forget but should still be observable."
            ),
            Fix.new(
              summary: "Use spawn_link if the parent should crash with the child",
              detail:
                "Replace `spawn` with `spawn_link` so the child's exit propagates to the parent. Useful when " <>
                  "the work is essential to the parent's correctness — losing it means the parent should fail too.",
              applies_when: "The work is integral to the parent."
            ),
            Fix.new(
              summary: "Use spawn_monitor if the parent only needs notification",
              detail:
                "`spawn_monitor` returns `{pid, ref}` and sends a `{:DOWN, ref, :process, pid, reason}` message " <>
                  "to the parent. Pair it with a handler that decides what to do on death. Don't forget to demonitor.",
              applies_when: "The parent needs to know about death but not crash with the child."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#5.21"],
          context: %{arity: length(args)},
          file: file,
          line: AST.line(meta)
        )
      end)
    end
  end

end
