defmodule Archdo.Rules.OTP.RestartTypeMismatch do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.7"

  @impl true
  def description, do: "Restart type must match process lifecycle (permanent/transient/temporary)"

  @impl true
  def analyze(file, ast, _opts) do
    find_child_spec_mismatches(file, ast)
  end

  defp find_child_spec_mismatches(file, ast) do
    # Look for child_spec/1 definitions with explicit :restart option
    child_specs = find_child_specs(ast)

    module_kind = classify_module(ast)

    Enum.flat_map(child_specs, fn {restart_type, meta} ->
      check_restart_match(file, module_kind, restart_type, meta)
    end)
  end

  defp find_child_specs(ast) do
    AST.find_all(ast, fn
      {:%{}, _meta, pairs} when is_list(pairs) ->
        Enum.any?(pairs, fn
          {{:__block__, _, [:restart]}, _} -> true
          {:restart, _} -> true
          _ -> false
        end)

      _ ->
        false
    end)
    |> Enum.map(fn {:%{}, meta, pairs} ->
      restart_value =
        Enum.find_value(pairs, fn
          {{:__block__, _, [:restart]}, val} -> extract_atom(val)
          {:restart, val} -> extract_atom(val)
          _ -> nil
        end)

      {restart_value, meta}
    end)
    |> Enum.reject(fn {v, _} -> is_nil(v) end)
  end

  defp extract_atom({:__block__, _, [atom]}) when is_atom(atom), do: atom
  defp extract_atom(atom) when is_atom(atom), do: atom
  defp extract_atom(_), do: nil

  defp classify_module(ast) do
    cond do
      uses?(ast, GenServer) ->
        :genserver

      uses?(ast, Supervisor) or uses?(ast, DynamicSupervisor) ->
        # Supervisors can legitimately be temporary (per-request, per-tenant)
        :supervisor

      uses?(ast, Task) ->
        :task

      has_run_function?(ast) ->
        :task

      true ->
        :unknown
    end
  end

  defp uses?(ast, target) do
    AST.contains?(ast, fn
      {:use, _, [{:__aliases__, _, aliases} | _]} -> Module.concat(aliases) == target
      _ -> false
    end)
  end

  defp has_run_function?(ast) do
    fns = AST.extract_functions(ast, :public)
    Enum.any?(fns, fn {name, arity, _, _, _} -> name == :run and arity in [0, 1] end)
  end

  defp check_restart_match(file, :task, :permanent, meta) do
    [
      Diagnostic.warning("5.7",
        title: "Permanent restart on task-like process",
        message: "Task-like module specifies restart: :permanent in its child spec",
        why:
          "Tasks are intended to run to completion. Marking one `:permanent` means OTP restarts it as soon as " <>
            "it finishes — including on a successful normal exit. The task loop fires repeatedly, hits " <>
            "max_restarts within seconds, and brings down the supervisor.",
        alternatives: [
          Fix.new(
            summary: "Switch the restart type to `:transient`",
            detail:
              "`:transient` restarts on abnormal exits only. Successful runs are left alone, but a crash still " <>
                "produces a restart so transient errors don't silently lose work.",
            applies_when: "The task can finish normally and you only care about crashes."
          ),
          Fix.new(
            summary: "Switch the restart type to `:temporary`",
            detail:
              "Use `:temporary` if the work should never restart automatically — for one-shot or request-scoped " <>
                "operations where retrying is the caller's responsibility.",
            applies_when: "The task is request-scoped or one-shot."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#5.7"],
        context: %{kind: :task_permanent},
        file: file,
        line: AST.line(meta)
      )
    ]
  end

  defp check_restart_match(file, :genserver, :temporary, meta) do
    [
      Diagnostic.warning("5.7",
        title: "Temporary restart on long-running GenServer",
        message: "Long-running GenServer specifies restart: :temporary in its child spec",
        why:
          "`:temporary` means the supervisor will never restart this child, even on crash. For a long-running " <>
            "GenServer that drops the service silently — callers continue to send messages to a now-dead pid " <>
            "and there is no log entry from the supervisor.",
        alternatives: [
          Fix.new(
            summary: "Switch to `:permanent`",
            detail:
              "GenServers that should always be available should use `:permanent`. The supervisor restarts the " <>
                "process on any exit, and any state lost is rebuilt by `init/1`.",
            applies_when: "The GenServer must always be running."
          ),
          Fix.new(
            summary: "Switch to `:transient`",
            detail:
              "If the GenServer can complete its work and exit normally (`{:stop, :normal, _}`), use `:transient` " <>
                "so it restarts only on crashes.",
            applies_when: "The GenServer has a defined end-of-life condition."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#5.7"],
        context: %{kind: :genserver_temporary},
        file: file,
        line: AST.line(meta)
      )
    ]
  end

  defp check_restart_match(_, _, _, _), do: []
end
