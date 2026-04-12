defmodule Archdo.Rules.OTP.MonitorWithoutHandler do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.20"

  @impl true
  def description, do: "Process.monitor must have a corresponding :DOWN handler"

  @impl true
  def analyze(file, ast, _opts) do
    if not AST.genserver_module?(ast) do
      []
    else
      check_monitors(file, ast) ++ check_trap_exit(file, ast)
    end
  end

  defp check_monitors(file, ast) do
    has_monitor? =
      AST.contains?(ast, fn
        {{:., _, [{:__aliases__, _, [:Process]}, :monitor]}, _, _} -> true
        _ -> false
      end)

    has_down_handler? =
      AST.contains?(ast, fn
        # handle_info({:DOWN, ...}, state) pattern
        {:def, _, [{:handle_info, _, [{:{}, _, [:DOWN | _]} | _]} | _]} -> true
        {:def, _, [{:handle_info, _, [{:__block__, _, [:DOWN]} | _]} | _]} -> true
        _ -> false
      end)

    if has_monitor? and not has_down_handler? do
      monitors =
        AST.find_all(ast, fn
          {{:., _, [{:__aliases__, _, [:Process]}, :monitor]}, _, _} -> true
          _ -> false
        end)

      Enum.map(monitors, fn {_, meta, _} ->
        Diagnostic.warning("5.20",
          title: "Process.monitor without :DOWN handler",
          message: "Process.monitor/1 is called but no handle_info({:DOWN, ...}) clause exists",
          why:
            "The whole point of monitoring is to react when the other process dies. Without a `:DOWN` handler " <>
              "the monitor message piles up unhandled in the mailbox, the death goes unnoticed by the calling " <>
              "code, and any pids/refs the calling state still holds become silent dangling references.",
          alternatives: [
            Fix.new(
              summary: "Add an explicit handle_info({:DOWN, ...}) clause",
              detail:
                "Match on `{:DOWN, ref, :process, pid, reason}` and decide what the GenServer should do — log " <>
                  "the death, drop the ref from state, restart the watched process, etc. Always demonitor refs " <>
                  "you no longer care about with `Process.demonitor(ref, [:flush])`.",
              example: """
              ```elixir
              def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
                Logger.warning("monitored \#{inspect(pid)} down: \#{inspect(reason)}")
                {:noreply, drop_pid(state, pid)}
              end
              ```
              """,
              applies_when: "You actually need to react when the monitored process dies."
            ),
            Fix.new(
              summary: "Replace Process.monitor with Task.async/await or links",
              detail:
                "If the only reason for monitoring is to await one task, use `Task.async`/`Task.await` (which " <>
                  "handles the monitor internally). If you want crash propagation rather than handling, use " <>
                  "`Process.link/1` instead.",
              applies_when: "Monitoring isn't actually the right primitive."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#5.20"],
          context: %{kind: :monitor},
          file: file,
          line: AST.line(meta)
        )
      end)
    else
      []
    end
  end

  defp check_trap_exit(file, ast) do
    has_trap_exit? =
      AST.contains?(ast, fn
        {{:., _, [{:__aliases__, _, [:Process]}, :flag]}, _, [:trap_exit, true]} -> true
        _ -> false
      end)

    has_exit_handler? =
      AST.contains?(ast, fn
        {:def, _, [{:handle_info, _, [{:{}, _, [:EXIT | _]} | _]} | _]} -> true
        {:def, _, [{:handle_info, _, [{:__block__, _, [:EXIT]} | _]} | _]} -> true
        _ -> false
      end)

    if has_trap_exit? and not has_exit_handler? do
      traps =
        AST.find_all(ast, fn
          {{:., _, [{:__aliases__, _, [:Process]}, :flag]}, _, [:trap_exit, true]} -> true
          _ -> false
        end)

      Enum.map(traps, fn {_, meta, _} ->
        Diagnostic.warning("5.20",
          title: "trap_exit without :EXIT handler",
          message: "Process.flag(:trap_exit, true) is set but no handle_info({:EXIT, ...}) clause exists",
          why:
            "Trapping exits converts every linked process death into an `:EXIT` message. Without a handler the " <>
              "messages accumulate, the linked-process deaths are invisible, and the GenServer behaves as if " <>
              "nothing happened — which silently breaks the supervision contract you opted into.",
          alternatives: [
            Fix.new(
              summary: "Add an explicit handle_info({:EXIT, pid, reason}, state) clause",
              detail:
                "Pattern-match on `{:EXIT, pid, reason}` and decide how the GenServer should react — clean up " <>
                  "associated state, restart a worker, propagate the failure further. Always log unexpected " <>
                  "exits so you can diagnose later.",
              example: """
              ```elixir
              def handle_info({:EXIT, pid, reason}, state) do
                Logger.warning("linked \#{inspect(pid)} exited: \#{inspect(reason)}")
                {:noreply, drop_pid(state, pid)}
              end
              ```
              """,
              applies_when: "You really need to trap exits and react to linked-process deaths."
            ),
            Fix.new(
              summary: "Remove the trap_exit if you don't need it",
              detail:
                "Most GenServers should not trap exits — letting them crash and being restarted by the " <>
                  "supervisor is the standard OTP pattern. If you only enabled trap_exit to make terminate/2 run " <>
                  "on `:shutdown`, that's already the supervisor's default behaviour.",
              applies_when: "trap_exit was added by reflex rather than necessity."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#5.20"],
          context: %{kind: :trap_exit},
          file: file,
          line: AST.line(meta)
        )
      end)
    else
      []
    end
  end
end
