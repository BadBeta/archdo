defmodule Archdo.Compiled.Graph do
  @moduledoc false

  # Complete interaction graph built from compiled beam files.
  #
  # §§ M-Plan19 (Phase 2) — `Compiled.Graph` is now BUILDER-ONLY.
  # Owns the struct, the `analyze/1` (`build/1`) entry point that
  # reads BEAM files and builds the indexed graph, and the
  # form-extraction helpers used during the build pass. Every
  # function that takes a `%Graph{}` and returns derived data has
  # moved to `Archdo.Compiled.Query`. The `%Graph{}` data shape
  # remains the contract both sides operate on — Query takes a
  # Graph in, builder produces one out.
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

  # §§ M-Plan19 Phase 3 — opaque per elixir-planning §4.12. External
  # callers must use accessor functions on `Archdo.Compiled` (calls/1,
  # modules/1, calls_by_module/1, calls_by_callee/1, calls_by_caller/1,
  # beam_dir/1). Dialyzer warns on any external pattern-match on these
  # fields. The struct shape is private — future swaps (ETS-backed
  # graph, partial graph, remote graph) won't break callers.
  @opaque t :: %__MODULE__{
            modules: %{module() => module_info()},
            calls: [call()],
            calls_by_caller: %{mfa_tuple() => [call()]},
            calls_by_callee: %{mfa_tuple() => [call()]},
            calls_by_module: %{module() => [call()]},
            protocol_impls: %{module() => [module()]},
            struct_expansions: [
              %{user_module: module(), struct_module: module(), line: non_neg_integer()}
            ],
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

  # §§ M-Plan19 Phase 3 — accessor functions per elixir-planning §4.12.
  # Live on Graph (the type's defining module) because @opaque opacity
  # is per-module: only Graph may destructure its own struct. The
  # `Archdo.Compiled` facade re-exports these via defdelegate.

  @spec calls(t()) :: [call()]
  def calls(%__MODULE__{calls: calls}), do: calls

  @spec modules(t()) :: %{module() => module_info()}
  def modules(%__MODULE__{modules: modules}), do: modules

  @spec calls_by_module(t()) :: %{module() => [call()]}
  def calls_by_module(%__MODULE__{calls_by_module: by_mod}), do: by_mod

  @spec calls_by_callee(t()) :: %{mfa_tuple() => [call()]}
  def calls_by_callee(%__MODULE__{calls_by_callee: by_callee}), do: by_callee

  @spec calls_by_caller(t()) :: %{mfa_tuple() => [call()]}
  def calls_by_caller(%__MODULE__{calls_by_caller: by_caller}), do: by_caller

  @spec beam_dir(t()) :: String.t() | nil
  def beam_dir(%__MODULE__{beam_dir: dir}), do: dir

  @spec protocol_impls(t()) :: %{module() => [module()]}
  def protocol_impls(%__MODULE__{protocol_impls: impls}), do: impls

  @doc """
  Stamp the graph with project-level metadata after the build.
  Lives here so callers don't need to destructure the opaque struct.
  """
  @spec with_metadata(t(), keyword()) :: t()
  def with_metadata(%__MODULE__{} = graph, opts) do
    %{
      graph
      | app_name: Keyword.get(opts, :app_name, graph.app_name),
        beam_dir: Keyword.get(opts, :beam_dir, graph.beam_dir)
    }
  end

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
    |> Enum.flat_map(fn beam_path ->
      case :beam_lib.chunks(to_charlist(beam_path), [:abstract_code]) do
        {:ok, {mod, [{:abstract_code, {:raw_abstract_v1, forms}}]}} ->
          exports = collect_exports_from_forms(forms)
          [{mod, extract_fns(forms, exports)}]

        # Malformed BEAM, stripped abstract code, etc. — skip rather
        # than create a fresh atom from the file basename (atom-table
        # exhaustion). The module won't appear in the function-clause
        # map; rules consuming this map already handle missing entries.
        _ ->
          []
      end
    end)
    |> Map.new()
  end

  @doc """
  Extracts the export list from Erlang abstract forms as a MapSet of `{name, arity}` tuples.
  """
  @spec collect_exports_from_forms(list()) :: MapSet.t({atom(), non_neg_integer()})
  def collect_exports_from_forms(forms) do
    forms
    |> Enum.flat_map(fn
      {:attribute, _, :export, exports} -> exports
      _ -> []
    end)
    |> MapSet.new()
  end

  defp extract_fns(forms, exports) do
    Enum.flat_map(forms, fn
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

        [
          %{
            name: name,
            arity: arity,
            exported: exported,
            clauses: clause_info,
            has_catch_all: has_any_catch_all,
            clause_count: length(clause_info)
          }
        ]

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
      Enum.map(catch_clauses, fn {:clause, _, _pats, _guards, cbody} -> classify_return(cbody) end)

    all_shapes = Enum.uniq([body_shape | catch_shapes])

    case all_shapes do
      [single] -> single
      multiple -> {:mixed, multiple}
    end
  end

  defp classify_expr(_), do: :unknown

  # --- Build Helpers (Private) ---

  # `:beam_lib.info/1` reads the module atom from the BEAM file's
  # metadata — the atom is already encoded in the file (not freshly
  # created from a string), so this avoids the `String.to_atom`
  # atom-table-exhaustion vector that the file-basename approach has.
  defp load_modules(beam_files) do
    beam_files
    |> Enum.flat_map(&module_atom_from_beam/1)
    |> Enum.filter(fn mod ->
      case Code.ensure_loaded(mod) do
        {:module, _} -> true
        {:error, _} -> false
      end
    end)
  end

  defp module_atom_from_beam(beam_path) do
    case :beam_lib.info(String.to_charlist(beam_path)) do
      info when is_list(info) ->
        case Keyword.fetch(info, :module) do
          {:ok, mod} when is_atom(mod) -> [mod]
          _ -> []
        end

      _ ->
        []
    end
  end

  defp collect_module_data(modules) do
    Map.new(modules, fn mod ->
      exports =
        Enum.reject(mod.module_info(:exports), fn {func, _arity} ->
          func in [:module_info, :__info__, :__struct__]
        end)

      behaviours =
        mod.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      struct_fields = collect_struct_fields(mod)
      callback_fns = collect_callback_fns(mod)

      {mod,
       %{
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
          # `__struct__/0` is exported as a function, not a struct accessor —
          # rare but happens for macro-generated `defstruct` shapes.
          UndefinedFunctionError -> []
          ArgumentError -> []
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
          # Some macro-generated modules export `behaviour_info/1` but
          # raise on `:callbacks`. Treat as "no callbacks discoverable."
          UndefinedFunctionError -> []
          FunctionClauseError -> []
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

    %{
      graph
      | calls_by_caller: calls_by_caller,
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
    mod.__impl__(:protocol)
  rescue
    # `__impl__/1` exists only on protocol-implementation modules.
    # Anything else raises UndefinedFunctionError; treat as "not an impl."
    UndefinedFunctionError -> nil
  end
end
