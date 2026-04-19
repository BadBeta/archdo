defmodule Archdo.Compiled.Graph do
  @moduledoc false

  # Complete interaction graph built from compiled beam files.
  #
  # This is a pure data structure — all functions are pure transformations.
  # Only `Archdo.Compiled.analyze/1` performs I/O (reading beam files).
  #
  # Nodes: modules with exports, behaviours, struct fields
  # Edges: function calls (caller MFA → callee MFA, with file/line)
  # Indexes: calls_by_caller, calls_by_callee, calls_by_module
  # Extra: protocol_impls, struct_expansions

  @type mfa_tuple :: {module(), atom(), non_neg_integer()}

  @type call :: %{
          caller: mfa_tuple(),
          callee: mfa_tuple(),
          line: non_neg_integer()
        }

  @type module_info :: %{
          exports: [{atom(), non_neg_integer()}],
          behaviours: [module()],
          struct_fields: [atom()],
          callback_fns: [{atom(), non_neg_integer()}]
        }

  @type t :: %__MODULE__{
          modules: %{module() => module_info()},
          calls: [call()],
          calls_by_caller: %{mfa_tuple() => [call()]},
          calls_by_callee: %{mfa_tuple() => [call()]},
          calls_by_module: %{module() => [call()]},
          protocol_impls: %{module() => [module()]},
          struct_expansions: [%{user_module: module(), struct_module: module(), line: non_neg_integer()}],
          app_name: String.t() | nil,
          beam_dir: String.t() | nil
        }

  defstruct modules: %{},
            calls: [],
            calls_by_caller: %{},
            calls_by_callee: %{},
            calls_by_module: %{},
            protocol_impls: %{},
            struct_expansions: [],
            app_name: nil,
            beam_dir: nil

  @doc """
  Build a complete interaction graph from compiled beam files in the given directory.

  Reads all Elixir.*.beam files, extracts exports, behaviours, callbacks,
  structs, and remote function calls. Builds indexed lookups in a single pass.
  """
  @spec build(String.t()) :: t()
  def build(beam_dir) do
    beam_files =
      beam_dir
      |> Path.join("Elixir.*.beam")
      |> Path.wildcard()

    beam_charlist = to_charlist(beam_dir)
    Code.prepend_path(beam_charlist)

    try do
      modules = load_modules(beam_files)

      raw_calls = collect_calls(beam_files)
      module_data = collect_module_data(modules)

      calls = normalize_calls(raw_calls)

      %__MODULE__{
        modules: module_data,
        calls: calls,
        beam_dir: beam_dir
      }
      |> build_indexes()
      |> detect_protocol_impls(modules)
    after
      Code.delete_path(beam_charlist)
    end
  end

  # --- Query Functions ---

  @doc """
  All callers of a specific function (who calls this MFA?).
  """
  @spec callers_of(t(), mfa_tuple()) :: [call()]
  def callers_of(%__MODULE__{calls_by_callee: index}, mfa) do
    Map.get(index, mfa, [])
  end

  @doc """
  All callees of a specific function (what does this MFA call?).
  """
  @spec callees_of(t(), mfa_tuple()) :: [call()]
  def callees_of(%__MODULE__{calls_by_caller: index}, mfa) do
    Map.get(index, mfa, [])
  end

  @doc """
  All modules that the given module calls (outgoing module-level dependencies).
  """
  @spec module_dependencies(t(), module()) :: [module()]
  def module_dependencies(%__MODULE__{calls_by_module: index}, module) do
    index
    |> Map.get(module, [])
    |> Enum.map(fn call -> elem(call.callee, 0) end)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == module))
  end

  @doc """
  All modules that call the given module (incoming module-level dependencies).
  """
  @spec module_dependents(t(), module()) :: [module()]
  def module_dependents(%__MODULE__{calls: calls}, module) do
    calls
    |> Enum.filter(fn call -> elem(call.callee, 0) == module end)
    |> Enum.map(fn call -> elem(call.caller, 0) end)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == module))
  end

  @doc """
  Find exported functions that are never called from outside their module.
  Excludes framework callbacks and behaviour callbacks.
  """
  @spec dead_functions(t()) :: [%{module: module(), function: atom(), arity: non_neg_integer()}]
  def dead_functions(%__MODULE__{modules: modules, calls_by_callee: callee_index}) do
    # Build per-module set of behaviour callback functions
    behaviour_fns = build_behaviour_fns(modules)

    modules
    |> Enum.flat_map(fn {module, info} ->
      module_callbacks = Map.get(behaviour_fns, module, MapSet.new())

      info.exports
      |> Enum.reject(fn {func, arity} ->
        framework_callback?(func, arity) or
          MapSet.member?(module_callbacks, {func, arity}) or
          has_external_callers?(callee_index, module, func, arity)
      end)
      |> Enum.map(fn {func, arity} ->
        %{module: module, function: func, arity: arity}
      end)
    end)
  end

  @doc """
  Find strongly connected components in the function call graph using Tarjan's algorithm.
  Returns a list of SCCs, each being a list of MFA tuples.
  Only returns SCCs with 2+ members (actual cycles).
  """
  @spec strongly_connected_components(t()) :: [[mfa_tuple()]]
  def strongly_connected_components(%__MODULE__{calls_by_caller: caller_index}) do
    # Collect all nodes that participate in calls
    nodes =
      caller_index
      |> Enum.flat_map(fn {caller, calls} ->
        [caller | Enum.map(calls, & &1.callee)]
      end)
      |> Enum.uniq()

    tarjan_scc(nodes, caller_index)
    |> Enum.filter(fn scc -> length(scc) > 1 end)
  end

  @doc """
  Count how many external modules call each exported function of the given module.
  Returns a map of {function, arity} => external_caller_count.
  """
  @spec external_usage(t(), module()) :: %{{atom(), non_neg_integer()} => non_neg_integer()}
  def external_usage(%__MODULE__{calls_by_callee: callee_index, modules: modules}, module) do
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

  @doc """
  Get all callback functions defined by a behaviour module.
  """
  @spec callbacks_for(t(), module()) :: [{atom(), non_neg_integer()}]
  def callbacks_for(%__MODULE__{modules: modules}, behaviour) do
    case Map.get(modules, behaviour) do
      %{callback_fns: fns} -> fns
      _ -> []
    end
  end

  @doc """
  Compute transitive dependents — all modules affected (directly or indirectly)
  by a change to the given module. Returns modules grouped by depth.
  """
  @spec transitive_dependents(t(), module()) :: %{non_neg_integer() => [module()]}
  def transitive_dependents(%__MODULE__{} = graph, module) do
    walk_dependents(graph, [module], MapSet.new([module]), %{}, 1)
  end

  @doc """
  Compute the blast radius for changing a module.
  Returns a report map with risk assessment.
  """
  @spec blast_radius(t(), module()) :: %{
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
  def blast_radius(%__MODULE__{modules: modules} = graph, module) do
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

    mod_info = Map.get(modules, module, %{exports: [], behaviours: [], struct_fields: [], callback_fns: []})
    defines_struct = mod_info.struct_fields != []
    defines_behaviour = mod_info.callback_fns != []

    # How many functions in this module are called externally
    usage = external_usage(graph, module)
    functions_called = Enum.count(usage, fn {_fa, count} -> count > 0 end)

    # Risk score: weighted combination of factors
    # Struct/behaviour changes cause broader recompilation than function-only changes
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

  @doc """
  Extract function clause information from beam files for API analysis.
  Returns a map of module => [%{name, arity, exported, clauses}].

  Each clause has:
    - patterns: the Erlang abstract format patterns
    - guards: guard expressions
    - return_shape: the shape of the last expression (simplified)
    - has_catch_all: whether the clause is a catch-all (all args are variables)
  """
  @spec extract_function_clauses(String.t()) :: %{module() => [map()]}
  def extract_function_clauses(beam_dir) do
    beam_dir
    |> Path.join("Elixir.*.beam")
    |> Path.wildcard()
    |> Map.new(fn beam_path ->
      charlist = to_charlist(beam_path)

      case :beam_lib.chunks(charlist, [:abstract_code]) do
        {:ok, {mod, [{:abstract_code, {:raw_abstract_v1, forms}}]}} ->
          exports = collect_exports_from_forms(forms)
          fns = extract_fns(forms, exports)
          {mod, fns}

        _ ->
          mod =
            beam_path
            |> Path.basename(".beam")
            |> String.to_atom()

          {mod, []}
      end
    end)
  end

  defp walk_dependents(_graph, [], _visited, by_depth, _depth), do: by_depth

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
        new_visited = Enum.reduce(next_level, visited, &MapSet.put(&2, &1))
        new_by_depth = Map.put(by_depth, depth, next_level)
        walk_dependents(graph, next_level, new_visited, new_by_depth, depth + 1)
    end
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

  defp collect_exports_from_forms(forms) do
    forms
    |> Enum.flat_map(fn
      {:attribute, _, :export, exports} -> exports
      _ -> []
    end)
    |> MapSet.new()
  end

  defp extract_fns(forms, exports) do
    forms
    |> Enum.flat_map(fn
      {:function, _line, name, arity, clauses}
      when name not in [:__info__, :module_info] ->
        exported = MapSet.member?(exports, {name, arity})

        clause_info =
          Enum.map(clauses, fn {:clause, _, args, guards, body} ->
            %{
              patterns: args,
              guards: guards,
              return_shape: classify_return(body),
              has_catch_all: catch_all_clause?(args, guards)
            }
          end)

        has_any_catch_all = Enum.any?(clause_info, & &1.has_catch_all)

        [%{
          name: name,
          arity: arity,
          exported: exported,
          clauses: clause_info,
          has_catch_all: has_any_catch_all,
          clause_count: length(clause_info)
        }]

      _ ->
        []
    end)
  end

  defp catch_all_clause?(args, guards) do
    # A clause is a catch-all if all args are variables (no pattern matching)
    # and there are no guards
    guards == [] and Enum.all?(args, &variable_pattern?/1)
  end

  defp variable_pattern?({:var, _, _}), do: true
  defp variable_pattern?(_), do: false

  @doc false
  # Classify the return shape of a function body (last expression)
  def classify_return([]), do: :unknown

  def classify_return(body) do
    last = List.last(body)
    classify_expr(last)
  end

  defp classify_expr({:tuple, _, [{:atom, _, tag} | _rest]}) do
    {:tagged_tuple, tag}
  end

  defp classify_expr({:atom, _, value}), do: {:atom, value}

  defp classify_expr({:case, _, _expr, clauses}) do
    shapes =
      clauses
      |> Enum.map(fn {:clause, _, _pats, _guards, body} -> classify_return(body) end)
      |> Enum.uniq()

    case shapes do
      [single] -> single
      multiple -> {:mixed, multiple}
    end
  end

  defp classify_expr({:call, _, _, _}), do: :call
  defp classify_expr({:var, _, _}), do: :variable
  defp classify_expr({:map, _, _}), do: :map
  defp classify_expr({:map, _, _base, _updates}), do: :map
  defp classify_expr({:cons, _, _, _}), do: :list
  defp classify_expr({nil, _}), do: :list
  defp classify_expr({:bin, _, _}), do: :binary
  defp classify_expr({:integer, _, _}), do: :integer
  defp classify_expr({:float, _, _}), do: :float
  defp classify_expr({:match, _, _lhs, rhs}), do: classify_expr(rhs)

  defp classify_expr({:try, _, body, _of_clauses, catch_clauses, _after}) do
    body_shape = classify_return(body)

    catch_shapes =
      catch_clauses
      |> Enum.map(fn {:clause, _, _pats, _guards, cbody} -> classify_return(cbody) end)

    all_shapes = Enum.uniq([body_shape | catch_shapes])

    case all_shapes do
      [single] -> single
      multiple -> {:mixed, multiple}
    end
  end

  defp classify_expr(_), do: :unknown

  # --- Build Helpers (Private) ---

  defp load_modules(beam_files) do
    beam_files
    |> Enum.map(fn path ->
      path
      |> Path.basename(".beam")
      |> String.to_atom()
    end)
    |> Enum.filter(fn mod ->
      case Code.ensure_loaded(mod) do
        {:module, _} -> true
        {:error, _} -> false
      end
    end)
  end

  defp collect_module_data(modules) do
    Map.new(modules, fn mod ->
      exports =
        mod.module_info(:exports)
        |> Enum.reject(fn {func, _arity} ->
          func in [:module_info, :__info__, :__struct__]
        end)

      behaviours =
        mod.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      struct_fields = collect_struct_fields(mod)
      callback_fns = collect_callback_fns(mod)

      {mod, %{
        exports: exports,
        behaviours: behaviours,
        struct_fields: struct_fields,
        callback_fns: callback_fns
      }}
    end)
  end

  defp collect_struct_fields(mod) do
    case function_exported?(mod, :__struct__, 0) do
      true ->
        try do
          mod.__struct__()
          |> Map.keys()
          |> Enum.reject(&(&1 == :__struct__))
        rescue
          _ -> []
        end

      false ->
        []
    end
  end

  defp collect_callback_fns(mod) do
    case function_exported?(mod, :behaviour_info, 1) do
      true ->
        try do
          mod.behaviour_info(:callbacks)
        rescue
          _ -> []
        end

      false ->
        []
    end
  end

  defp collect_calls(beam_files) do
    Enum.flat_map(beam_files, fn beam_path ->
      charlist = to_charlist(beam_path)

      case :beam_lib.chunks(charlist, [:abstract_code]) do
        {:ok, {caller_mod, [{:abstract_code, {:raw_abstract_v1, forms}}]}} ->
          extract_calls_from_forms(caller_mod, forms)

        _ ->
          []
      end
    end)
  end

  defp extract_calls_from_forms(caller_mod, forms) do
    Enum.flat_map(forms, fn
      {:function, _line, func_name, func_arity, clauses} ->
        caller = {caller_mod, func_name, func_arity}

        clauses
        |> Enum.flat_map(&find_remote_calls(&1))
        |> Enum.map(fn {callee_mod, callee_func, callee_arity, line} ->
          %{
            caller: caller,
            callee: {callee_mod, callee_func, callee_arity},
            line: line
          }
        end)

      _ ->
        []
    end)
  end

  defp find_remote_calls(form) do
    case form do
      {:call, line, {:remote, _, {:atom, _, mod}, {:atom, _, func}}, args} ->
        [{mod, func, length(args), line}]

      tuple when is_tuple(tuple) ->
        tuple
        |> Tuple.to_list()
        |> Enum.flat_map(&find_remote_calls/1)

      list when is_list(list) ->
        Enum.flat_map(list, &find_remote_calls/1)

      _ ->
        []
    end
  end

  defp normalize_calls(raw_calls) do
    Enum.uniq_by(raw_calls, fn call ->
      {call.caller, call.callee, call.line}
    end)
  end

  defp build_indexes(%__MODULE__{calls: calls} = graph) do
    calls_by_caller = Enum.group_by(calls, & &1.caller)
    calls_by_callee = Enum.group_by(calls, & &1.callee)

    calls_by_module =
      Enum.group_by(calls, fn call -> elem(call.caller, 0) end)

    %{graph |
      calls_by_caller: calls_by_caller,
      calls_by_callee: calls_by_callee,
      calls_by_module: calls_by_module
    }
  end

  defp detect_protocol_impls(%__MODULE__{modules: modules} = graph, _all_modules) do
    # Protocol implementations follow the naming convention:
    # Protocol.Module.Implementation (e.g., String.Chars.MyStruct)
    # They also have @protocol and @for attributes
    impls =
      modules
      |> Enum.filter(fn {mod, info} ->
        # Protocol impls declare the protocol as a behaviour-like dependency
        # and have the __impl__ function
        Enum.any?(info.exports, fn {func, arity} -> func == :__impl__ and arity == 1 end) and
          impl_protocol(mod) != nil
      end)
      |> Enum.group_by(
        fn {mod, _info} -> impl_protocol(mod) end,
        fn {mod, _info} -> mod end
      )

    %{graph | protocol_impls: impls}
  end

  defp impl_protocol(mod) do
    try do
      mod.__impl__(:protocol)
    rescue
      _ -> nil
    end
  end

  defp build_behaviour_fns(modules) do
    # Build a map: module => MapSet of {func, arity} that are behaviour callbacks
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

  # --- Tarjan's SCC Algorithm ---

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
    state = %{state |
      indexes: Map.put(state.indexes, v, state.index),
      lowlinks: Map.put(state.lowlinks, v, state.index),
      index: state.index + 1,
      stack: [v | state.stack],
      on_stack: MapSet.put(state.on_stack, v)
    }

    # Process all successors
    successors =
      adjacency
      |> Map.get(v, [])
      |> Enum.map(& &1.callee)
      |> Enum.uniq()

    state =
      Enum.reduce(successors, state, fn w, acc ->
        cond do
          not Map.has_key?(acc.indexes, w) ->
            # w has not been visited; recurse
            acc = tarjan_strongconnect(w, adjacency, acc)
            lowlink_v = Map.get(acc.lowlinks, v)
            lowlink_w = Map.get(acc.lowlinks, w)
            %{acc | lowlinks: Map.put(acc.lowlinks, v, min(lowlink_v, lowlink_w))}

          MapSet.member?(acc.on_stack, w) ->
            # w is on the stack — part of current SCC
            lowlink_v = Map.get(acc.lowlinks, v)
            index_w = Map.get(acc.indexes, w)
            %{acc | lowlinks: Map.put(acc.lowlinks, v, min(lowlink_v, index_w))}

          true ->
            acc
        end
      end)

    # If v is a root node, pop the SCC
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
end
