defmodule Archdo.Compiled.Query do
  @moduledoc false

  # §§ M-Plan19 (Phase 2) — read API of the Compiled context. Owns
  # every function that takes a `%Graph{}` and returns derived data.
  # `Compiled.Graph` retains only the BUILDER (struct + analyze/1 +
  # ingest helpers + Tarjan SCC stay there if used by build path).
  # The split makes the responsibilities explicit: Graph constructs
  # the data shape; Query reads it.
  #
  # Type signatures continue to mention `%Graph{}` because Graph still
  # owns the struct definition — that is the data contract both sides
  # operate on.

  alias Archdo.Compiled.Graph

  @type mfa_tuple :: Graph.mfa_tuple()
  @type call :: Graph.call()

  @type awareness_entry :: %{
          module: module(),
          functions_called: [{atom(), non_neg_integer()}],
          call_count: non_neg_integer()
        }

  @type context_report :: %{
          context: String.t(),
          members: [module()],
          boundary_module: module() | nil,
          internal_calls: non_neg_integer(),
          incoming_calls: non_neg_integer(),
          outgoing_calls: non_neg_integer(),
          boundary_calls: non_neg_integer(),
          leak_calls: non_neg_integer(),
          cohesion: float(),
          coupling: float(),
          quality_score: float(),
          leaking_modules: [%{module: module(), external_callers: non_neg_integer()}],
          misplaced_modules: [
            %{
              module: module(),
              calls_to_own: non_neg_integer(),
              calls_to_other: non_neg_integer(),
              strongest_affinity: String.t()
            }
          ]
        }

  # --- Function-level lookups ---

  @doc "All callers of a specific function (who calls this MFA?)."
  @spec callers_of(Graph.t(), mfa_tuple()) :: [call()]
  def callers_of(graph, mfa) do
    graph |> Graph.calls_by_callee() |> Map.get(mfa, [])
  end

  @doc "All callees of a specific function (what does this MFA call?)."
  @spec callees_of(Graph.t(), mfa_tuple()) :: [call()]
  def callees_of(graph, mfa) do
    graph |> Graph.calls_by_caller() |> Map.get(mfa, [])
  end

  # --- Module-level dependencies ---

  @doc "All modules that the given module calls (outgoing module-level dependencies)."
  @spec module_dependencies(Graph.t(), module()) :: [module()]
  def module_dependencies(graph, module) do
    index = Graph.calls_by_module(graph)

    for call <- Map.get(index, module, []),
        callee = elem(call.callee, 0),
        callee != module,
        uniq: true,
        do: callee
  end

  @doc "All modules that call the given module (incoming module-level dependencies)."
  @spec module_dependents(Graph.t(), module()) :: [module()]
  def module_dependents(graph, module) do
    for call <- Graph.calls(graph),
        elem(call.callee, 0) == module,
        caller = elem(call.caller, 0),
        caller != module,
        uniq: true,
        do: caller
  end

  # --- Dead code detection ---

  @doc """
  Find exported functions that are never called from outside their module.
  Excludes framework callbacks and behaviour callbacks.
  """
  @spec dead_functions(Graph.t()) :: [%{module: module(), function: atom(), arity: non_neg_integer()}]
  def dead_functions(graph) do
    modules = Graph.modules(graph)
    callee_index = Graph.calls_by_callee(graph)
    behaviour_fns = build_behaviour_fns(modules)

    for {module, info} <- modules,
        module_callbacks = Map.get(behaviour_fns, module, MapSet.new()),
        {func, arity} <- info.exports,
        not framework_callback?(func, arity),
        not MapSet.member?(module_callbacks, {func, arity}),
        not has_external_callers?(callee_index, module, func, arity) do
      %{module: module, function: func, arity: arity}
    end
  end

  defp build_behaviour_fns(modules) do
    Map.new(modules, fn {module, info} ->
      callback_set =
        info.behaviours
        |> Enum.flat_map(fn bhv ->
          case Map.get(modules, bhv) do
            %{callback_fns: fns} -> fns
            _ -> []
          end
        end)
        |> MapSet.new()

      {module, callback_set}
    end)
  end

  defp has_external_callers?(callee_index, module, func, arity) do
    mfa = {module, func, arity}

    callee_index
    |> Map.get(mfa, [])
    |> Enum.any?(fn call -> elem(call.caller, 0) != module end)
  end

  # Framework callbacks that shouldn't be flagged as dead code
  @framework_fns ~w(
    init child_spec start_link handle_call handle_cast handle_info
    handle_continue terminate code_change format_status callback_mode
    mount render handle_event handle_params handle_async update
    changeset __changeset__ __schema__ __struct__
    behaviour_info __using__ __before_compile__ __after_compile__
    __impl__ __protocol__ __deriving__
  )a

  defp framework_callback?(func, _arity), do: func in @framework_fns

  # --- SCC (Tarjan) ---

  @doc """
  Find strongly connected components in the function call graph using Tarjan's algorithm.
  Returns a list of SCCs, each being a list of MFA tuples.
  Only returns SCCs with 2+ members (actual cycles).
  """
  @spec strongly_connected_components(Graph.t()) :: [[mfa_tuple()]]
  def strongly_connected_components(graph) do
    caller_index = Graph.calls_by_caller(graph)

    nodes =
      caller_index
      |> Enum.flat_map(fn {caller, calls} ->
        [caller | Enum.map(calls, & &1.callee)]
      end)
      |> Enum.uniq()

    Enum.filter(tarjan_scc(nodes, caller_index), fn scc -> length(scc) > 1 end)
  end

  defp tarjan_scc(nodes, adjacency) do
    state = %{
      index: 0,
      stack: [],
      on_stack: MapSet.new(),
      indexes: %{},
      lowlinks: %{},
      sccs: []
    }

    result =
      Enum.reduce(nodes, state, fn node, acc ->
        case Map.has_key?(acc.indexes, node) do
          true -> acc
          false -> tarjan_strongconnect(node, adjacency, acc)
        end
      end)

    result.sccs
  end

  defp tarjan_strongconnect(v, adjacency, state) do
    state = %{
      state
      | indexes: Map.put(state.indexes, v, state.index),
        lowlinks: Map.put(state.lowlinks, v, state.index),
        index: state.index + 1,
        stack: [v | state.stack],
        on_stack: MapSet.put(state.on_stack, v)
    }

    successors =
      adjacency
      |> Map.get(v, [])
      |> Enum.map(& &1.callee)
      |> Enum.uniq()

    state =
      Enum.reduce(successors, state, fn w, acc ->
        cond do
          not Map.has_key?(acc.indexes, w) ->
            acc = tarjan_strongconnect(w, adjacency, acc)
            lowlink_v = Map.get(acc.lowlinks, v)
            lowlink_w = Map.get(acc.lowlinks, w)
            %{acc | lowlinks: Map.put(acc.lowlinks, v, min(lowlink_v, lowlink_w))}

          MapSet.member?(acc.on_stack, w) ->
            lowlink_v = Map.get(acc.lowlinks, v)
            index_w = Map.get(acc.indexes, w)
            %{acc | lowlinks: Map.put(acc.lowlinks, v, min(lowlink_v, index_w))}

          true ->
            acc
        end
      end)

    case Map.get(state.lowlinks, v) == Map.get(state.indexes, v) do
      true ->
        {scc, remaining_stack, remaining_on_stack} = pop_scc(v, state.stack, state.on_stack, [])
        %{state | stack: remaining_stack, on_stack: remaining_on_stack, sccs: [scc | state.sccs]}

      false ->
        state
    end
  end

  defp pop_scc(v, [w | rest], on_stack, acc) do
    on_stack = MapSet.delete(on_stack, w)

    case w == v do
      true -> {[w | acc], rest, on_stack}
      false -> pop_scc(v, rest, on_stack, [w | acc])
    end
  end

  # --- External usage / callbacks ---

  @doc """
  Count how many external modules call each exported function of the given module.
  Returns a map of {function, arity} => external_caller_count.
  """
  @spec external_usage(Graph.t(), module()) :: %{{atom(), non_neg_integer()} => non_neg_integer()}
  def external_usage(graph, module) do
    callee_index = Graph.calls_by_callee(graph)
    modules = Graph.modules(graph)
    exports = Map.get(modules, module, %{exports: []}).exports

    Map.new(exports, fn {func, arity} ->
      mfa = {module, func, arity}
      callers = Map.get(callee_index, mfa, [])

      external_count =
        callers
        |> Enum.map(fn call -> elem(call.caller, 0) end)
        |> Enum.uniq()
        |> Enum.reject(&(&1 == module))
        |> length()

      {{func, arity}, external_count}
    end)
  end

  @doc "Get all callback functions defined by a behaviour module."
  @spec callbacks_for(Graph.t(), module()) :: [{atom(), non_neg_integer()}]
  def callbacks_for(graph, behaviour) do
    case Map.get(Graph.modules(graph), behaviour) do
      %{callback_fns: fns} -> fns
      _ -> []
    end
  end

  # --- Transitive dependents / blast radius ---

  @doc """
  Compute transitive dependents — all modules affected (directly or indirectly)
  by a change to the given module. Returns modules grouped by depth.
  """
  @spec transitive_dependents(Graph.t(), module()) :: %{non_neg_integer() => [module()]}
  def transitive_dependents(graph, module) do
    walk_dependents(graph, [module], MapSet.new([module]), %{}, 1)
  end

  defp walk_dependents(graph, frontier, visited, by_depth, depth) do
    next_level =
      frontier
      |> Enum.flat_map(fn mod -> module_dependents(graph, mod) end)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(visited, &1))

    case next_level do
      [] ->
        by_depth

      _ ->
        new_visited = MapSet.union(visited, MapSet.new(next_level))
        new_by_depth = Map.put(by_depth, depth, next_level)
        walk_dependents(graph, next_level, new_visited, new_by_depth, depth + 1)
    end
  end

  @doc """
  Compute the blast radius for changing a module.
  Returns a report map with risk assessment.
  """
  @spec blast_radius(Graph.t(), module()) :: %{
          module: module(),
          direct_dependents: [module()],
          transitive_dependents: %{non_neg_integer() => [module()]},
          total_affected: non_neg_integer(),
          max_depth: non_neg_integer(),
          defines_struct: boolean(),
          defines_behaviour: boolean(),
          functions_called: non_neg_integer(),
          risk_score: float()
        }
  def blast_radius(graph, module) do
    modules = Graph.modules(graph)
    direct = module_dependents(graph, module)
    transitive = transitive_dependents(graph, module)

    total_affected =
      transitive
      |> Map.values()
      |> List.flatten()
      |> length()

    max_depth =
      case Map.keys(transitive) do
        [] -> 0
        keys -> Enum.max(keys)
      end

    mod_info =
      Map.get(modules, module, %{exports: [], behaviours: [], struct_fields: [], callback_fns: []})

    defines_struct = mod_info.struct_fields != []
    defines_behaviour = mod_info.callback_fns != []

    usage = external_usage(graph, module)
    functions_called = Enum.count(usage, fn {_fa, count} -> count > 0 end)

    risk_score = compute_risk_score(total_affected, max_depth, defines_struct, defines_behaviour)

    %{
      module: module,
      direct_dependents: direct,
      transitive_dependents: transitive,
      total_affected: total_affected,
      max_depth: max_depth,
      defines_struct: defines_struct,
      defines_behaviour: defines_behaviour,
      functions_called: functions_called,
      risk_score: risk_score
    }
  end

  defp compute_risk_score(total_affected, max_depth, defines_struct, defines_behaviour) do
    base = total_affected * 1.0

    depth_weight =
      case max_depth do
        0 -> 0.0
        d -> :math.log(d + 1) * 2
      end

    struct_weight =
      case defines_struct do
        true -> total_affected * 0.5
        false -> 0.0
      end

    behaviour_weight =
      case defines_behaviour do
        true -> total_affected * 0.3
        false -> 0.0
      end

    base + depth_weight + struct_weight + behaviour_weight
  end

  # --- Module awareness ---

  @doc """
  What does this module know about? Returns all modules it calls,
  with which functions and how many times.
  """
  @spec knows_about(Graph.t(), module()) :: [awareness_entry()]
  def knows_about(graph, module) do
    index = Graph.calls_by_module(graph)
    modules = Graph.modules(graph)
    project_modules = MapSet.new(Map.keys(modules))

    index
    |> Map.get(module, [])
    |> Enum.group_by(fn call -> elem(call.callee, 0) end)
    |> Enum.filter(fn {target, _calls} ->
      target != module and MapSet.member?(project_modules, target)
    end)
    |> Enum.map(fn {target, calls} ->
      fns =
        calls
        |> Enum.map(fn call -> {elem(call.callee, 1), elem(call.callee, 2)} end)
        |> Enum.uniq()
        |> Enum.sort()

      %{module: target, functions_called: fns, call_count: length(calls)}
    end)
    |> Enum.sort_by(& &1.call_count, :desc)
  end

  @doc """
  Who knows about this module? Returns all modules that call it,
  with which functions they call and how many times.
  """
  @spec known_by(Graph.t(), module()) :: [awareness_entry()]
  def known_by(graph, module) do
    calls = Graph.calls(graph)
    modules = Graph.modules(graph)
    project_modules = MapSet.new(Map.keys(modules))

    calls
    |> Enum.filter(fn call ->
      elem(call.callee, 0) == module and
        elem(call.caller, 0) != module and
        MapSet.member?(project_modules, elem(call.caller, 0))
    end)
    |> Enum.group_by(fn call -> elem(call.caller, 0) end)
    |> Enum.map(fn {caller, caller_calls} ->
      fns =
        caller_calls
        |> Enum.map(fn call -> {elem(call.callee, 1), elem(call.callee, 2)} end)
        |> Enum.uniq()
        |> Enum.sort()

      %{module: caller, functions_called: fns, call_count: length(caller_calls)}
    end)
    |> Enum.sort_by(& &1.call_count, :desc)
  end

  @doc """
  What does this context know about? Returns all external contexts it calls into,
  with the specific modules and call counts.
  """
  @spec context_knows_about(Graph.t(), String.t()) :: [
          %{context: String.t(), modules_called: [module()], call_count: non_neg_integer()}
        ]
  def context_knows_about(graph, context_name) do
    contexts = discover_contexts(graph)
    context_of = build_context_membership(contexts)

    members =
      contexts
      |> Enum.find(fn c -> c.context == context_name end)
      |> case do
        nil -> []
        ctx -> ctx.members
      end

    member_set = MapSet.new(members)

    members
    |> Enum.flat_map(fn mod -> knows_about(graph, mod) end)
    |> Enum.reject(fn entry -> MapSet.member?(member_set, entry.module) end)
    |> Enum.group_by(fn entry -> Map.get(context_of, entry.module, "external") end)
    |> Enum.map(fn {target_ctx, entries} ->
      modules_called =
        entries
        |> Enum.map(& &1.module)
        |> Enum.uniq()

      total_calls = Enum.sum(Enum.map(entries, & &1.call_count))

      %{context: target_ctx, modules_called: modules_called, call_count: total_calls}
    end)
    |> Enum.sort_by(& &1.call_count, :desc)
  end

  @doc """
  Who knows about this context? Returns all external contexts that call into it,
  with the specific modules and call counts.
  """
  @spec context_known_by(Graph.t(), String.t()) :: [
          %{context: String.t(), calling_modules: [module()], call_count: non_neg_integer()}
        ]
  def context_known_by(graph, context_name) do
    contexts = discover_contexts(graph)
    context_of = build_context_membership(contexts)

    members =
      contexts
      |> Enum.find(fn c -> c.context == context_name end)
      |> case do
        nil -> []
        ctx -> ctx.members
      end

    member_set = MapSet.new(members)

    members
    |> Enum.flat_map(fn mod -> known_by(graph, mod) end)
    |> Enum.reject(fn entry -> MapSet.member?(member_set, entry.module) end)
    |> Enum.group_by(fn entry -> Map.get(context_of, entry.module, "external") end)
    |> Enum.map(fn {source_ctx, entries} ->
      calling_modules =
        entries
        |> Enum.map(& &1.module)
        |> Enum.uniq()

      total_calls = Enum.sum(Enum.map(entries, & &1.call_count))

      %{context: source_ctx, calling_modules: calling_modules, call_count: total_calls}
    end)
    |> Enum.sort_by(& &1.call_count, :desc)
  end

  @doc "Build a lookup map from module atoms to their owning context name strings."
  @spec build_context_membership([map()]) :: %{atom() => String.t()}
  def build_context_membership(contexts) do
    contexts
    |> Enum.flat_map(fn ctx ->
      Enum.map(ctx.members, fn mod -> {mod, ctx.context} end)
    end)
    |> Map.new()
  end

  # --- Context discovery ---

  @doc """
  Discover domain contexts automatically from namespace structure and call patterns.

  Groups project modules by their top-level namespace (e.g., MyApp.Accounts.*),
  then analyzes call patterns to compute cohesion, coupling, and boundary quality
  for each group.
  """
  @spec discover_contexts(Graph.t()) :: [context_report()]
  def discover_contexts(graph) do
    modules = Graph.modules(graph)
    calls = Graph.calls(graph)
    project_modules = Map.keys(modules)

    app_prefix = detect_app_prefix(project_modules)
    groups = group_by_context(project_modules, app_prefix)

    groups
    |> Enum.map(fn {context_name, member_modules} ->
      analyze_context(graph, context_name, member_modules, calls, project_modules)
    end)
    |> Enum.filter(fn report -> length(report.members) >= 2 end)
    |> Enum.sort_by(& &1.quality_score)
  end

  defp detect_app_prefix(modules) do
    modules
    |> Enum.map(fn mod ->
      mod
      |> Module.split()
      |> List.first()
    end)
    |> Enum.frequencies()
    |> Enum.max_by(fn {_prefix, count} -> count end, fn -> {"App", 0} end)
    |> elem(0)
  end

  defp group_by_context(modules, app_prefix) do
    Enum.group_by(modules, fn mod ->
      parts = Module.split(mod)

      case parts do
        [^app_prefix, context | _] -> "#{app_prefix}.#{context}"
        [^app_prefix] -> app_prefix
        _ -> Enum.join(Enum.take(parts, 2), ".")
      end
    end)
  end

  defp analyze_context(graph, context_name, members, all_calls, project_modules) do
    member_set = MapSet.new(members)
    project_set = MapSet.new(project_modules)

    boundary_module =
      Enum.find(members, fn mod ->
        mod
        |> Module.split()
        |> Enum.join(".") ==
          context_name
      end)

    {internal, incoming, outgoing, boundary_incoming, leak_incoming} =
      classify_context_calls(all_calls, member_set, project_set, boundary_module)

    internal_count = length(internal)
    incoming_count = length(incoming)
    outgoing_count = length(outgoing)
    boundary_count = length(boundary_incoming)
    leak_count = length(leak_incoming)

    total_calls = internal_count + incoming_count + outgoing_count

    cohesion =
      case total_calls do
        0 -> 1.0
        _ -> internal_count / total_calls
      end

    coupling =
      case total_calls do
        0 -> 0.0
        _ -> (incoming_count + outgoing_count) / total_calls
      end

    leak_ratio =
      case incoming_count do
        0 -> 0.0
        _ -> leak_count / incoming_count
      end

    quality_score = cohesion * (1.0 - leak_ratio)

    leaking_modules = find_leaking_modules(leak_incoming, boundary_module)
    misplaced = find_misplaced_modules(graph, members, member_set, project_set, context_name)

    %{
      context: context_name,
      members: members,
      boundary_module: boundary_module,
      internal_calls: internal_count,
      incoming_calls: incoming_count,
      outgoing_calls: outgoing_count,
      boundary_calls: boundary_count,
      leak_calls: leak_count,
      cohesion: Float.round(cohesion, 3),
      coupling: Float.round(coupling, 3),
      quality_score: Float.round(quality_score, 3),
      leaking_modules: leaking_modules,
      misplaced_modules: misplaced
    }
  end

  defp classify_context_calls(all_calls, member_set, project_set, boundary_module) do
    Enum.reduce(all_calls, {[], [], [], [], []}, fn call,
                                                    {internal, incoming, outgoing, boundary_in,
                                                     leak_in} ->
      caller_mod = elem(call.caller, 0)
      callee_mod = elem(call.callee, 0)
      caller_in = MapSet.member?(member_set, caller_mod)
      callee_in = MapSet.member?(member_set, callee_mod)
      caller_project = MapSet.member?(project_set, caller_mod)
      callee_project = MapSet.member?(project_set, callee_mod)

      cond do
        caller_in and callee_in ->
          {[call | internal], incoming, outgoing, boundary_in, leak_in}

        not caller_in and callee_in and caller_project ->
          case callee_mod == boundary_module do
            true ->
              {internal, [call | incoming], outgoing, [call | boundary_in], leak_in}

            false ->
              {internal, [call | incoming], outgoing, boundary_in, [call | leak_in]}
          end

        caller_in and not callee_in and callee_project ->
          {internal, incoming, [call | outgoing], boundary_in, leak_in}

        true ->
          {internal, incoming, outgoing, boundary_in, leak_in}
      end
    end)
  end

  defp find_leaking_modules(leak_calls, boundary_module) do
    leak_calls
    |> Enum.group_by(fn call -> elem(call.callee, 0) end)
    |> Enum.reject(fn {mod, _calls} -> mod == boundary_module end)
    |> Enum.map(fn {mod, calls} ->
      external_callers =
        calls
        |> Enum.map(fn call -> elem(call.caller, 0) end)
        |> Enum.uniq()
        |> length()

      %{module: mod, external_callers: external_callers}
    end)
    |> Enum.sort_by(& &1.external_callers, :desc)
  end

  defp find_misplaced_modules(graph, members, member_set, project_set, context_name) do
    Enum.flat_map(members, fn mod ->
      deps = module_dependencies(graph, mod)

      own_calls =
        Enum.count(deps, fn dep ->
          MapSet.member?(member_set, dep)
        end)

      other_context_calls =
        Enum.filter(deps, fn dep ->
          MapSet.member?(project_set, dep) and not MapSet.member?(member_set, dep)
        end)

      other_count = length(other_context_calls)

      case other_count > own_calls and other_count >= 3 do
        true ->
          strongest =
            other_context_calls
            |> Enum.map(fn dep ->
              dep
              |> Module.split()
              |> Enum.take(2)
              |> Enum.join(".")
            end)
            |> Enum.frequencies()
            |> Enum.max_by(fn {_ctx, count} -> count end, fn -> {context_name, 0} end)
            |> elem(0)

          [
            %{
              module: mod,
              calls_to_own: own_calls,
              calls_to_other: other_count,
              strongest_affinity: strongest
            }
          ]

        false ->
          []
      end
    end)
  end
end
