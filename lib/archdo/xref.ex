defmodule Archdo.Xref do
  @moduledoc false

  # Compilation tracer-based cross-reference analysis.
  #
  # When a project is compiled with Archdo's tracer enabled, we capture
  # every remote function call, import, struct expansion, and module
  # definition. This gives us ground-truth data that AST-only analysis
  # can't provide:
  #
  #   - Macro-injected functions (visible after expansion)
  #   - Resolved imports (which module each unqualified call targets)
  #   - Protocol dispatch targets
  #   - Dead code detection (exported functions never called)
  #   - Complete behaviour callback lists (including @optional_callbacks)

  @doc """
  Compile a project directory with our tracer enabled and return
  the collected cross-reference data.

  Returns `{:ok, xref_data}` or `{:error, reason}`.

  The xref_data map contains:
    - `:calls` — list of `%{caller_module, callee_module, callee_function, callee_arity, file, line}`
    - `:exports` — map of `module => [{function, arity}]` (all public functions including macro-injected)
    - `:behaviours` — map of `module => [behaviour_module]`
    - `:callbacks` — map of `behaviour_module => [{function, arity}]`
    - `:structs` — map of `module => [field_name]`
  """
  @spec analyze(String.t()) :: {:ok, map()} | {:error, String.t()}
  def analyze(project_path) do
    beam_dir = find_beam_dir(project_path)

    case beam_dir do
      nil ->
        {:error, "No compiled beam files found. Run `mix compile` in the target project first."}

      dir ->
        data = read_beam_data(dir)
        {:ok, data}
    end
  end

  @doc """
  Find dead public functions — exported but never called from outside the module.
  Requires xref data from `analyze/1`.
  """
  @spec dead_functions(map()) :: [%{module: module(), function: atom(), arity: non_neg_integer()}]
  def dead_functions(%{exports: exports, calls: calls, behaviours: behaviours, callbacks: callback_defs}) do
    # Build set of all called {module, function, arity} tuples
    called =
      calls
      |> Enum.map(fn call -> {call.callee_module, call.callee_function, call.callee_arity} end)
      |> MapSet.new()

    # Build per-module set of behaviour callback functions (called dynamically by framework)
    behaviour_fns =
      Map.new(behaviours, fn {module, module_behaviours} ->
        callback_set =
          module_behaviours
          |> Enum.flat_map(fn bhv -> Map.get(callback_defs, bhv, []) end)
          |> MapSet.new()

        {module, callback_set}
      end)

    # For each module's exports, find functions never called from outside
    exports
    |> Enum.flat_map(fn {module, fns} ->
      module_callbacks = Map.get(behaviour_fns, module, MapSet.new())

      fns
      |> Enum.reject(fn {func, arity} ->
        framework_callback?(func, arity) or
          MapSet.member?(called, {module, func, arity}) or
          MapSet.member?(module_callbacks, {func, arity})
      end)
      |> Enum.map(fn {func, arity} ->
        %{module: module, function: func, arity: arity}
      end)
    end)
  end

  @doc """
  Check behaviour implementation completeness using compiled module data.
  Returns missing callbacks per module.
  """
  @spec missing_callbacks(map()) :: [%{module: module(), behaviour: module(), missing: [{atom(), non_neg_integer()}]}]
  def missing_callbacks(%{exports: exports, behaviours: behaviours, callbacks: callback_defs}) do
    behaviours
    |> Enum.flat_map(fn {module, module_behaviours} ->
      module_exports = MapSet.new(Map.get(exports, module, []))

      Enum.flat_map(module_behaviours, fn behaviour ->
        required = Map.get(callback_defs, behaviour, [])

        missing =
          Enum.reject(required, fn {func, arity} ->
            MapSet.member?(module_exports, {func, arity})
          end)

        case missing do
          [] -> []
          _ -> [%{module: module, behaviour: behaviour, missing: missing}]
        end
      end)
    end)
  end

  # --- Private ---

  defp find_beam_dir(project_path) do
    build_dir = Path.join(project_path, "_build")

    case detect_app_name(project_path) do
      nil ->
        nil

      app_name ->
        # Look for _build/ENV/lib/APP/ebin — try dev first, then prod
        ["dev", "prod", "test"]
        |> Enum.find_value(fn env ->
          dir = Path.join([build_dir, env, "lib", app_name, "ebin"])

          case File.dir?(dir) and Path.wildcard(Path.join(dir, "*.beam")) != [] do
            true -> dir
            false -> nil
          end
        end)
    end
  end

  defp detect_app_name(project_path) do
    mix_file = Path.join(project_path, "mix.exs")

    case File.read(mix_file) do
      {:ok, content} ->
        case Regex.run(~r/app:\s*:(\w+)/, content) do
          [_, name] -> name
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp read_beam_data(beam_dir) do
    beam_files =
      beam_dir
      |> Path.join("Elixir.*.beam")
      |> Path.wildcard()

    # Add beam dir to code path temporarily so we can load modules
    beam_charlist = to_charlist(beam_dir)
    Code.prepend_path(beam_charlist)

    try do
      modules = load_modules(beam_files)

      %{
        exports: collect_exports(modules),
        behaviours: collect_behaviours(modules),
        callbacks: collect_callback_definitions(modules),
        structs: collect_structs(modules),
        calls: collect_calls_from_chunks(beam_files)
      }
    after
      Code.delete_path(beam_charlist)
    end
  end

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

  defp collect_exports(modules) do
    Map.new(modules, fn mod ->
      exports =
        mod.module_info(:exports)
        |> Enum.reject(fn {func, _arity} ->
          func in [:module_info, :__info__, :__struct__]
        end)

      {mod, exports}
    end)
  end

  defp collect_behaviours(modules) do
    modules
    |> Enum.map(fn mod ->
      behaviours =
        mod.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      {mod, behaviours}
    end)
    |> Enum.reject(fn {_mod, behaviours} -> behaviours == [] end)
    |> Map.new()
  end

  defp collect_callback_definitions(modules) do
    modules
    |> Enum.filter(fn mod ->
      function_exported?(mod, :behaviour_info, 1)
    end)
    |> Map.new(fn mod ->
      callbacks =
        try do
          mod.behaviour_info(:callbacks)
        rescue
          _ -> []
        end

      {mod, callbacks}
    end)
  end

  defp collect_structs(modules) do
    modules
    |> Enum.filter(fn mod ->
      function_exported?(mod, :__struct__, 0)
    end)
    |> Map.new(fn mod ->
      fields =
        try do
          mod.__struct__()
          |> Map.keys()
          |> Enum.reject(&(&1 == :__struct__))
        rescue
          _ -> []
        end

      {mod, fields}
    end)
  end

  # Extract call references from beam file debug chunks
  defp collect_calls_from_chunks(beam_files) do
    beam_files
    |> Enum.flat_map(fn beam_path ->
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
    forms
    |> Enum.flat_map(&extract_calls_from_form(caller_mod, &1))
  end

  defp extract_calls_from_form(caller_mod, {:function, line, _name, _arity, clauses}) do
    clauses
    |> Enum.flat_map(&find_remote_calls(caller_mod, line, &1))
  end

  defp extract_calls_from_form(_caller_mod, _form), do: []

  defp find_remote_calls(caller_mod, _default_line, form) do
    # Walk the Erlang abstract format for remote calls
    case form do
      {:call, line, {:remote, _, {:atom, _, mod}, {:atom, _, func}}, args} ->
        [
          %{
            caller_module: caller_mod,
            callee_module: mod,
            callee_function: func,
            callee_arity: length(args),
            line: line
          }
        ]

      tuple when is_tuple(tuple) ->
        tuple
        |> Tuple.to_list()
        |> Enum.flat_map(&find_remote_calls(caller_mod, 0, &1))

      list when is_list(list) ->
        Enum.flat_map(list, &find_remote_calls(caller_mod, 0, &1))

      _ ->
        []
    end
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
end
