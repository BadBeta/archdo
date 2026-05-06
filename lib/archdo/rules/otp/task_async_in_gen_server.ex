defmodule Archdo.Rules.OTP.TaskAsyncInGenServer do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.65"

  @impl true
  def description,
    do:
      "`Task.async/1,2` inside a GenServer — task crash links into the GenServer; " <>
        "use Task.Supervisor.async_nolink/3"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    case AST.genserver_module?(ast) do
      false -> []
      true -> find_task_async_calls(file, ast)
    end
  end

  defp find_task_async_calls(file, ast) do
    Enum.map(AST.find_all(ast, &task_async_call?/1), fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta))
    end)
  end

  # `Task.async(args)` — the LINKED form. NOT `Task.Supervisor.async_nolink/3`
  # which is the safe form (its dot-call shape has Task.Supervisor as the
  # alias).
  defp task_async_call?({{:., _, [{:__aliases__, _, [:Task]}, :async]}, _, args})
       when is_list(args),
       do: true

  defp task_async_call?(_), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.warning("5.65",
      title: "`Task.async` inside a GenServer — link propagates to the GenServer",
      message:
        "This GenServer calls `Task.async/1`, which LINKS the task to the calling process. " <>
          "If the task crashes, the GenServer crashes too. Use " <>
          "`Task.Supervisor.async_nolink/3` and handle the `:DOWN` message in `handle_info`.",
      why:
        "`Task.async/1` is convenient for synchronous-await use in regular processes, but " <>
          "inside a GenServer the link means an unrelated task failure tears down the " <>
          "GenServer (and any state it holds). The fix is `async_nolink` against a " <>
          "supervised Task.Supervisor: failures arrive as `:DOWN` messages the GenServer " <>
          "can handle gracefully.",
      alternatives: [
        Fix.new(
          summary: "Use Task.Supervisor.async_nolink/3 + handle_info",
          detail:
            "task = Task.Supervisor.async_nolink(MyApp.TaskSup, fn -> work() end)\n" <>
              "{:noreply, %{state | task_ref: task.ref}}\n\n" <>
              "def handle_info({ref, result}, %{task_ref: ref} = state) do\n" <>
              "  Process.demonitor(ref, [:flush])\n" <>
              "  {:noreply, %{state | task_ref: nil, last_result: result}}\n" <>
              "end\n\n" <>
              "def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task_ref: ref} = state) do\n" <>
              "  {:noreply, %{state | task_ref: nil}}\n" <>
              "end",
          applies_when: "When the GenServer should survive task failures."
        )
      ],
      references: ["elixir-implementing/SKILL.md#9.9"],
      context: %{},
      file: file,
      line: line
    )
  end
end
