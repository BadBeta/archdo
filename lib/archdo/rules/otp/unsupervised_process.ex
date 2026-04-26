defmodule Archdo.Rules.OTP.UnsupervisedProcess do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.1"

  @impl true
  def description, do: "All long-running processes must be supervised"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      find_bare_spawns(file, ast) ++ find_unlinked_starts(file, ast)
    end
  end

  defp find_bare_spawns(file, ast) do
    Enum.map(
      AST.find_all(ast, fn
        {:spawn, _meta, args} when is_list(args) and length(args) in [1, 3] -> true
        {:spawn_link, _meta, args} when is_list(args) and length(args) in [1, 3] -> true
        _ -> false
      end),
      fn {name, meta, _} ->
        Diagnostic.warning("5.1",
          title: "Bare spawn outside supervision tree",
          message:
            "#{name}/#{call_arity(name, meta)} starts a process not registered with any supervisor",
          why:
            "Unsupervised processes are invisible to OTP: when they crash there is no restart, no logging, " <>
              "and they don't show up in Observer or LiveDashboard. The supervision tree is the architecture, " <>
              "and processes outside it leak silently and degrade the system over time.",
          alternatives: [
            Fix.new(
              summary: "Use `Task.Supervisor.start_child/2` for fire-and-forget work",
              detail:
                "Add a `Task.Supervisor` (e.g. `{Task.Supervisor, name: MyApp.TaskSupervisor}`) to your " <>
                  "application's supervision tree, then start the work with " <>
                  "`Task.Supervisor.start_child(MyApp.TaskSupervisor, fn -> ... end)`. The task is supervised, " <>
                  "logged on crash, and shut down cleanly when the application stops.",
              applies_when: "The work is short-lived and you don't need the result."
            ),
            Fix.new(
              summary: "Wrap the process in a GenServer/Worker child of a Supervisor",
              detail:
                "If the process is long-lived (a server, a polling loop, a connection holder), define it as a " <>
                  "GenServer/Agent/Task module and add it as a child of a Supervisor. Use `start_link/1` and let " <>
                  "the supervisor own its lifecycle.",
              applies_when: "The process is long-running and worth modeling explicitly."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#5.1"],
          context: %{call: "#{name}", kind: :spawn},
          file: file,
          line: AST.line(meta)
        )
      end
    )
  end

  defp find_unlinked_starts(file, ast) do
    # GenServer.start (not start_link), Agent.start (not start_link)
    Enum.map(
      AST.find_all(ast, fn
        {{:., _, [{:__aliases__, _, [:GenServer]}, :start]}, _meta, _args} -> true
        {{:., _, [{:__aliases__, _, [:Agent]}, :start]}, _meta, _args} -> true
        _ -> false
      end),
      fn {{:., _, [{:__aliases__, _, [mod]}, :start]}, meta, _} ->
        Diagnostic.warning("5.1",
          title: "Process started without link",
          message:
            "#{mod}.start/2 used instead of #{mod}.start_link — caller is not linked to the process",
          why:
            "`start/2` returns a pid but does not link the new process to the caller. If the caller dies the " <>
              "process is orphaned, and if the new process dies the caller never finds out. Without a link " <>
              "there is no supervisor relationship and no automatic cleanup.",
          alternatives: [
            Fix.new(
              summary: "Switch to `#{mod}.start_link/2` and add the module to a supervision tree",
              detail:
                "Replace `#{mod}.start/2` with `#{mod}.start_link/2` and add the module as a child of a " <>
                  "Supervisor (or DynamicSupervisor for runtime-spawned instances). The supervisor restarts the " <>
                  "process on failure and shuts it down cleanly with the rest of the application.",
              applies_when: "The process is part of the application — almost always."
            ),
            Fix.new(
              summary: "Keep `start/2` only if the process is intentionally detached",
              detail:
                "There are rare cases (test helpers, one-shot scripts) where you want a process untied to any " <>
                  "supervision tree. If that's the case, document the reason in a `# archdo:ignore 5.1` comment " <>
                  "or add it to the freeze baseline.",
              applies_when: "The unlinked start is a deliberate design choice."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#5.1"],
          context: %{call: "#{mod}.start", kind: :unlinked_start},
          file: file,
          line: AST.line(meta)
        )
      end
    )
  end

  defp call_arity(:spawn, _), do: "1,3"
  defp call_arity(:spawn_link, _), do: "1,3"
  defp call_arity(_, _), do: "?"
end
