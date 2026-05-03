defmodule Archdo.Rules.OTP.StalePidReference do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.36"

  @impl true
  def description,
    do: "PIDs stored in state or ETS without monitoring — become stale on process death"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      find_stale_pid_patterns(file, ast)
    end
  end

  defp find_stale_pid_patterns(file, ast) do
    fns = AST.extract_functions(ast, :all)

    Enum.flat_map(fns, fn {_name, _arity, _meta, _args, body} ->
      check_function_body(file, body)
    end)
  end

  defp check_function_body(_file, nil), do: []

  defp check_function_body(file, body) do
    stores_pid_in_ets?(body, file) ++ stores_pid_in_map_without_monitor?(body, file)
  end

  # Pattern: :ets.insert(table, {key, pid}) where pid comes from a variable
  # without a corresponding Process.monitor or Process.link in the same function
  defp stores_pid_in_ets?(body, file) do
    ets_inserts_with_pid =
      AST.find_all(body, fn
        {{:., _, [:ets, :insert]}, _, [_table, tuple]} ->
          tuple_contains_pid_variable?(tuple)

        _ ->
          false
      end)

    has_monitor =
      AST.contains?(body, fn
        {{:., _, [{:__aliases__, _, [:Process]}, :monitor]}, _, _} -> true
        {{:., _, [{:__aliases__, _, [:Process]}, :link]}, _, _} -> true
        {:monitor, _, _} -> true
        _ -> false
      end)

    if ets_inserts_with_pid != [] and not has_monitor do
      [
        build_diagnostic(file, extract_line(ets_inserts_with_pid), :ets)
      ]
    else
      []
    end
  end

  # Pattern: Map.put(state, :pid, pid) or %{state | pid: pid} without monitor
  defp stores_pid_in_map_without_monitor?(body, file) do
    stores_pid_field = AST.contains?(body, &pid_storing_node?/1)
    has_monitor = AST.contains?(body, &monitor_or_link_node?/1)
    emit_stale_map_diag(stores_pid_field and not has_monitor, file)
  end

  # %{state | pid: variable}
  defp pid_storing_node?({:%{}, _, [{:|, _, [_, pairs]}]}) when is_list(pairs),
    do: Enum.any?(pairs, &pid_pair?/1)

  # Map.put(state, :pid, variable)
  defp pid_storing_node?(
         {{:., _, [{:__aliases__, _, [:Map]}, :put]}, _, [_, key, _]}
       ),
       do: pid_key_value?(key)

  defp pid_storing_node?(_), do: false

  defp pid_pair?({key, {var, _, ctx}})
       when is_atom(key) and is_atom(var) and is_atom(ctx),
       do: pid_key?(key)

  defp pid_pair?({{:__block__, _, [key]}, {var, _, ctx}})
       when is_atom(key) and is_atom(var) and is_atom(ctx),
       do: pid_key?(key)

  defp pid_pair?(_), do: false

  defp monitor_or_link_node?({{:., _, [{:__aliases__, _, [:Process]}, :monitor]}, _, _}),
    do: true

  defp monitor_or_link_node?({{:., _, [{:__aliases__, _, [:Process]}, :link]}, _, _}),
    do: true

  defp monitor_or_link_node?(_), do: false

  defp emit_stale_map_diag(false, _file), do: []
  # Can't easily get the line, use 0
  defp emit_stale_map_diag(true, file), do: [build_diagnostic(file, 0, :map)]

  defp tuple_contains_pid_variable?({:{}, _, elements}) when is_list(elements) do
    Enum.any?(elements, fn
      {name, _, ctx} when is_atom(name) and is_atom(ctx) ->
        pid_variable?(name)

      _ ->
        false
    end)
  end

  defp tuple_contains_pid_variable?({_, _} = pair) do
    tuple_contains_pid_variable?({:{}, [], Tuple.to_list(pair)})
  end

  defp tuple_contains_pid_variable?(_), do: false

  defp pid_variable?(name) do
    name_str = Atom.to_string(name)
    String.contains?(name_str, "pid") or name_str == "from"
  end

  defp pid_key?(key) do
    key_str = Atom.to_string(key)
    String.contains?(key_str, "pid") or key_str in ~w(worker handler client server)
  end

  defp pid_key_value?({:__block__, _, [key]}) when is_atom(key), do: pid_key?(key)
  defp pid_key_value?(key) when is_atom(key), do: pid_key?(key)
  defp pid_key_value?(_), do: false

  defp extract_line([{_, meta, _} | _]), do: AST.line(meta)
  defp extract_line(_), do: 0

  defp build_diagnostic(file, line, storage_type) do
    storage_desc =
      case storage_type do
        :ets -> "ETS table"
        :map -> "process state map"
      end

    Diagnostic.info("5.36",
      title: "PID stored without monitor",
      message:
        "A PID is stored in #{storage_desc} without a corresponding Process.monitor/1 or Process.link/1",
      why:
        "PIDs reference a specific process incarnation. When that process dies, the PID becomes " <>
          "stale — messages sent to it are silently dropped, and GenServer.call raises an :exit. " <>
          "Without monitoring, the storing process never learns the referenced process died, leading " <>
          "to silent message loss, growing stale entries in ETS, or crashes on the next call attempt. " <>
          "Production systems (Supavisor, Finch, db_connection) always monitor PIDs they store.",
      alternatives: [
        Fix.new(
          summary: "Monitor the PID and handle :DOWN",
          detail:
            "Call `Process.monitor(pid)` when storing the PID, and add a `handle_info({:DOWN, ref, " <>
              ":process, pid, reason}, state)` clause to clean up the reference when the process dies.",
          example: """
          ```elixir
          # Store PID with monitor
          ref = Process.monitor(pid)
          state = %{state | workers: Map.put(state.workers, ref, pid)}

          # Clean up on death
          def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
            {:noreply, %{state | workers: Map.delete(state.workers, ref)}}
          end
          ```
          """,
          applies_when: "The PID reference should be cleaned up when the process dies."
        ),
        Fix.new(
          summary: "Use a Registry instead of storing PIDs directly",
          detail:
            "Registry handles cleanup automatically — when a registered process dies, its " <>
              "entry is removed. Use `Registry.lookup/2` to find processes by key, and " <>
              "`Registry.dispatch/3` to fan out to all registered processes.",
          applies_when: "You're building a process lookup table."
        ),
        Fix.new(
          summary: "Link instead of monitor if both should die together",
          detail:
            "If the storing process should crash when the referenced process dies, use " <>
              "`Process.link(pid)` instead. Links are bidirectional — either death kills both.",
          applies_when: "The processes are tightly coupled and should share fate."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#5.36"],
      context: %{storage: storage_type},
      file: file,
      line: line
    )
  end
end
