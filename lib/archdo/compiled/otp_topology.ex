defmodule Archdo.Compiled.OTPTopology do
  @moduledoc false

  # Extracts OTP process topology from compiled beam data.
  # Identifies GenServers, Supervisors, Agents, Tasks and their
  # message-passing relationships.

  alias Archdo.Compiled.Graph

  @type process_info :: %{
          module: module(),
          type: :genserver | :supervisor | :agent | :task | :gen_statem | :process,
          incoming_messages: [%{from: module(), type: :call | :cast | :send, function: atom()}],
          outgoing_messages: [%{to: module(), type: :call | :cast | :send, function: atom()}],
          children: [module()],
          supervision_strategy: atom() | nil
        }

  @doc """
  Extract the full OTP topology from the compiled graph.
  Returns a list of process descriptors with messaging relationships.
  """
  @spec extract(Graph.t()) :: [process_info()]
  def extract(graph) do
    modules = Graph.modules(graph)
    calls = Graph.calls(graph)

    # Identify process modules by behaviour
    process_modules =
      modules
      |> Enum.flat_map(fn {mod, info} ->
        type = classify_process_type(info.behaviours)

        case type do
          nil -> []
          t -> [{mod, t}]
        end
      end)
      |> Map.new()

    # Find messaging relationships from call graph
    messaging = extract_messaging(calls, process_modules, modules)

    # Find supervision relationships
    supervision = extract_supervision(calls, process_modules, modules)

    # Build process descriptors
    process_modules
    |> Enum.map(fn {mod, type} ->
      incoming = Map.get(messaging.incoming, mod, [])
      outgoing = Map.get(messaging.outgoing, mod, [])
      children = Map.get(supervision, mod, [])

      strategy = detect_strategy(mod, type, modules)

      %{
        module: mod,
        type: type,
        incoming_messages: incoming,
        outgoing_messages: outgoing,
        children: children,
        supervision_strategy: strategy
      }
    end)
    |> Enum.sort_by(fn p ->
      # Supervisors first, then by module name
      case p.type do
        :supervisor -> {0, Atom.to_string(p.module)}
        _ -> {1, Atom.to_string(p.module)}
      end
    end)
  end

  @doc """
  Build a supervision tree from the topology.
  Returns a nested tree structure suitable for rendering.
  """
  @spec supervision_tree([process_info()]) :: [tree_node()]
  def supervision_tree(topology) do
    # Find root supervisors (supervisors not supervised by anyone)
    all_children =
      topology
      |> Enum.flat_map(& &1.children)
      |> MapSet.new()

    supervisors =
      topology
      |> Enum.filter(&(&1.type == :supervisor))
      |> Map.new(&{&1.module, &1})

    roots =
      Enum.filter(topology, fn p ->
        p.type == :supervisor and not MapSet.member?(all_children, p.module)
      end)

    process_map = Map.new(topology, &{&1.module, &1})

    Enum.map(roots, fn root ->
      build_tree_node(root, process_map, supervisors, MapSet.new())
    end)
  end

  @type tree_node :: %{
          process: process_info(),
          children: [tree_node()]
        }

  defp build_tree_node(process, process_map, supervisors, visited) do
    # Prevent cycles
    case MapSet.member?(visited, process.module) do
      true ->
        %{process: process, children: []}

      false ->
        visited = MapSet.put(visited, process.module)

        child_nodes =
          Enum.flat_map(process.children, fn child_mod ->
            case Map.get(process_map, child_mod) do
              nil -> []
              child -> [build_tree_node(child, process_map, supervisors, visited)]
            end
          end)

        %{process: process, children: child_nodes}
    end
  end

  # --- Private helpers ---

  defp classify_process_type(behaviours) do
    cond do
      Supervisor in behaviours -> :supervisor
      GenServer in behaviours -> :genserver
      Agent in behaviours -> :agent
      :gen_statem in behaviours -> :gen_statem
      Task in behaviours -> :task
      true -> nil
    end
  end

  defp extract_messaging(calls, process_modules, _all_modules) do
    process_set = MapSet.new(Map.keys(process_modules))

    # Find calls that represent messaging: GenServer.call/cast, send, etc.
    # Also find direct calls between process modules' client API functions
    message_calls =
      Enum.flat_map(calls, fn call ->
        caller_mod = elem(call.caller, 0)
        callee_mod = elem(call.callee, 0)
        callee_fn = elem(call.callee, 1)

        cond do
          # GenServer.call/cast from a process module
          callee_mod == GenServer and callee_fn in [:call, :cast] ->
            # The target is typically the first argument — we can't easily
            # extract it from abstract code, but we know the caller
            case MapSet.member?(process_set, caller_mod) do
              true ->
                msg_type = if callee_fn == :call, do: :call, else: :cast
                [%{from: caller_mod, to: :unknown, type: msg_type, function: callee_fn}]

              false ->
                []
            end

          # Direct send via :erlang.send or Kernel.send
          callee_mod in [:erlang, Kernel] and callee_fn == :send ->
            case MapSet.member?(process_set, caller_mod) do
              true -> [%{from: caller_mod, to: :unknown, type: :send, function: :send}]
              false -> []
            end

          # One process module calling another process module's client API
          MapSet.member?(process_set, caller_mod) and
            MapSet.member?(process_set, callee_mod) and
              caller_mod != callee_mod ->
            [%{from: caller_mod, to: callee_mod, type: :call, function: callee_fn}]

          # Non-process calling a process module's client API
          not MapSet.member?(process_set, caller_mod) and
              MapSet.member?(process_set, callee_mod) ->
            [%{from: caller_mod, to: callee_mod, type: :call, function: callee_fn}]

          true ->
            []
        end
      end)

    # Group into incoming/outgoing per process
    incoming =
      message_calls
      |> Enum.filter(fn m -> m.to != :unknown end)
      |> Enum.group_by(& &1.to)

    outgoing =
      message_calls
      |> Enum.filter(fn m -> m.from != nil end)
      |> Enum.group_by(& &1.from)

    %{incoming: incoming, outgoing: outgoing}
  end

  defp extract_supervision(calls, process_modules, _all_modules) do
    # Find Supervisor modules and their children
    # Look for calls to child modules' start_link or child_spec from supervisor modules
    supervisor_mods =
      process_modules
      |> Enum.filter(fn {_mod, type} -> type == :supervisor end)
      |> Enum.map(fn {mod, _} -> mod end)
      |> MapSet.new()

    process_set = MapSet.new(Map.keys(process_modules))

    # A supervisor's children are modules whose start_link/child_spec
    # it references, or modules listed in its children spec
    calls
    |> Enum.filter(fn call ->
      caller_mod = elem(call.caller, 0)
      callee_fn = elem(call.callee, 1)

      MapSet.member?(supervisor_mods, caller_mod) and
        callee_fn in [:start_link, :child_spec, :start_child]
    end)
    |> Enum.group_by(
      fn call -> elem(call.caller, 0) end,
      fn call ->
        callee_mod = elem(call.callee, 0)
        # If calling Supervisor.start_child, the child is in the args
        # If calling SomeModule.start_link, SomeModule is the child
        case callee_mod do
          Supervisor -> nil
          DynamicSupervisor -> nil
          mod -> mod
        end
      end
    )
    |> Map.new(fn {sup, children} ->
      {sup,
       children
       |> Enum.reject(&is_nil/1)
       |> Enum.filter(&MapSet.member?(process_set, &1))
       |> Enum.uniq()}
    end)
  end

  defp detect_strategy(_mod, type, _modules) do
    case type do
      :supervisor -> :one_for_one
      _ -> nil
    end
  end
end
