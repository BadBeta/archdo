defmodule Archdo.FunctionGraph do
  @moduledoc false

  # Function-level call graph.
  #
  # Tracks:
  #   - Every function defined in the project: {module, name, arity}
  #     with metadata: visibility, doc-status, file, line, public_api?
  #   - Every function call: {caller_mfa, target_mfa, file, line}
  #
  # The graph supports:
  #   - Cross-context call analysis
  #   - Function fan-out (how many distinct modules a function calls)
  #   - Reverse lookup (who calls function X)

  alias Archdo.AST

  @stdlib ~w(Enum List Map MapSet Keyword Process Kernel IO File Path String Integer Float
             Atom Tuple Range Stream Function Module Code Macro Application System
             Logger GenServer Agent Task Supervisor DynamicSupervisor Registry
             Ecto Phoenix Plug)

  @type mfa_key :: {module :: String.t(), name :: atom(), arity :: non_neg_integer()}
  @type fn_def :: %{
          module: String.t(),
          name: atom(),
          arity: non_neg_integer(),
          visibility: :public | :private,
          doc_false?: boolean(),
          file: String.t(),
          line: non_neg_integer()
        }
  @type call :: %{
          caller_module: String.t(),
          caller_fn: atom() | nil,
          caller_arity: non_neg_integer() | nil,
          target_module: String.t(),
          target_fn: atom(),
          target_arity: non_neg_integer() | nil,
          file: String.t(),
          line: non_neg_integer()
        }

  @type t :: %__MODULE__{
          definitions: %{mfa_key() => fn_def()},
          calls: [call()],
          calls_by_target: %{mfa_key() => [call()]},
          public_api_by_module: %{String.t() => MapSet.t(mfa_key())}
        }

  defstruct definitions: %{},
            calls: [],
            calls_by_target: %{},
            public_api_by_module: %{}

  @doc """
  Build a function graph from a list of {file, ast} tuples.
  """
  @spec build([{String.t(), Macro.t()}]) :: t()
  def build(file_asts) do
    {definitions, calls} =
      Enum.reduce(file_asts, {%{}, []}, fn {file, ast}, {defs, calls} ->
        {file_defs, file_calls} = analyze_file(file, ast)
        {Map.merge(defs, file_defs), [file_calls | calls]}
      end)

    calls = List.flatten(calls)

    calls_by_target =
      Enum.group_by(calls, fn call ->
        {call.target_module, call.target_fn, call.target_arity}
      end)

    public_api_by_module = compute_public_api(definitions)

    %__MODULE__{
      definitions: definitions,
      calls: calls,
      calls_by_target: calls_by_target,
      public_api_by_module: public_api_by_module
    }
  end

  @doc """
  Get all calls originating from a specific function (forward edges).
  """
  @spec calls_from(t(), String.t(), atom(), non_neg_integer()) :: [call()]
  def calls_from(%__MODULE__{calls: calls}, module, name, arity) do
    Enum.filter(calls, fn call ->
      call.caller_module == module and call.caller_fn == name and call.caller_arity == arity
    end)
  end

  @doc """
  Get all calls TO a specific function (reverse edges).
  """
  @spec calls_to(t(), String.t(), atom(), non_neg_integer() | nil) :: [call()]
  def calls_to(%__MODULE__{calls_by_target: by_target}, module, name, arity) do
    Map.get(by_target, {module, name, arity}, [])
  end

  @doc """
  Determine if a function is part of the public API of its owning context.
  Public API = function defined directly in the context root module (not in sub-modules),
               with public visibility, and not @doc false.
  """
  @spec public_api?(t(), String.t(), atom(), non_neg_integer()) :: boolean()
  def public_api?(%__MODULE__{public_api_by_module: api}, context, name, arity) do
    case Map.get(api, context) do
      nil -> false
      set -> MapSet.member?(set, {context, name, arity})
    end
  end

  @doc """
  Compute fan-out for each function: how many distinct external modules it calls.
  Returns a map: {module, name, arity} => fan_out_count
  """
  @spec function_fan_out(t()) :: %{mfa_key() => non_neg_integer()}
  def function_fan_out(%__MODULE__{calls: calls}) do
    calls
    |> Enum.group_by(fn call -> {call.caller_module, call.caller_fn, call.caller_arity} end)
    |> Map.new(fn {key, function_calls} ->
      external_modules =
        function_calls
        |> Enum.map(fn call -> call.target_module end)
        |> Enum.reject(fn target -> target == elem(key, 0) or target in @stdlib end)
        |> Enum.uniq()

      {key, length(external_modules)}
    end)
  end

  # --- Internal ---

  defp analyze_file(file, ast) do
    # We need a recursive walk that maintains current_module AND current_function
    # state. Macro.prewalk can't easily express "this AST node is inside a def"
    # because the def's body is walked after the def header. Instead we do
    # explicit recursion.
    state = %{module: nil, function: nil, arity: nil, in_spec: false, defs: %{}, calls: [], file: file}
    state = walk(ast, state)
    {state.defs, state.calls}
  end

  # Module definition — body may be wrapped by literal_encoder, use helper
  defp walk({:defmodule, _meta, [{:__aliases__, _, aliases}, body_kw]}, state) do
    mod = case AST.safe_concat(aliases) do
      nil -> "Unknown"
      atom -> normalize_module(atom)
    end
    body = extract_do_body(body_kw)
    body_state = walk(body, %{state | module: mod})
    %{state | defs: body_state.defs, calls: body_state.calls}
  end

  # Public function definition
  defp walk({:def, meta, [head | rest]}, %{module: mod} = state) when mod != nil do
    {name, arity} = head_name_arity(head)
    state = record_def(state, mod, name, arity, :public, AST.line(meta))

    body = extract_def_body(rest)
    body_state = %{state | function: name, arity: arity}
    new_state = walk(body, body_state)

    %{new_state | function: state.function, arity: state.arity}
  end

  # Private function definition
  defp walk({:defp, meta, [head | rest]}, %{module: mod} = state) when mod != nil do
    {name, arity} = head_name_arity(head)
    state = record_def(state, mod, name, arity, :private, AST.line(meta))

    body = extract_def_body(rest)
    body_state = %{state | function: name, arity: arity}
    new_state = walk(body, body_state)

    %{new_state | function: state.function, arity: state.arity}
  end

  # @spec, @type, @callback, @typep, @opaque — skip type references (not real calls)
  defp walk({:@, _, [{attr, _, _} | _]} = node, state)
       when attr in [:spec, :type, :typep, :opaque, :callback, :macrocallback] do
    # Walk children with in_spec flag so remote references aren't recorded as calls
    then(walk_children(node, %{state | in_spec: true}), fn s -> %{s | in_spec: state.in_spec} end)
  end

  # Remote function call: Module.fn(args) — skip if inside @spec/@type
  defp walk(
         {{:., _, [{:__aliases__, _, aliases}, target_fn]}, meta, args} = _node,
         %{module: mod, in_spec: false} = state
       )
       when is_atom(target_fn) and mod != nil do
    target_mod = case AST.safe_concat(aliases) do
      nil -> "Unknown"
      atom -> normalize_module(atom)
    end
    target_arity = arg_count(args)

    call = %{
      caller_module: mod,
      caller_fn: state.function,
      caller_arity: state.arity,
      target_module: target_mod,
      target_fn: target_fn,
      target_arity: target_arity,
      file: state.file,
      line: AST.line(meta)
    }

    state = %{state | calls: [call | state.calls]}

    # Continue walking args (e.g., nested calls)
    walk(args, state)
  end

  # Generic AST walk: descend into all children
  defp walk({a, _meta, args}, state) do
    state = walk(a, state)
    walk(args, state)
  end

  defp walk({a, b}, state) do
    state = walk(a, state)
    walk(b, state)
  end

  defp walk(list, state) when is_list(list) do
    Enum.reduce(list, state, fn item, acc -> walk(item, acc) end)
  end

  defp walk(_, state), do: state

  # Walk children of an AST node without matching specific node types
  defp walk_children({_, _, args}, state) when is_list(args), do: walk(args, state)
  defp walk_children({a, b}, state) do
    state
    |> walk(a)
    |> walk(b)
  end
  defp walk_children(list, state) when is_list(list), do: Enum.reduce(list, state, &walk(&1, &2))
  defp walk_children(_, state), do: state

  # Body keyword list may be wrapped by literal_encoder.
  # Plain form: [do: body]
  # Wrapped form: [{{:__block__, _, [:do]}, body}]
  defp extract_do_body(list) when is_list(list) do
    Enum.find_value(list, fn
      {:do, body} -> body
      {{:__block__, _, [:do]}, body} -> body
      _ -> false
    end)
  end

  defp extract_do_body(_), do: nil

  # Function body — `def head, do: ...` produces [body] OR [body_kw_list]
  defp extract_def_body([body_kw]) when is_list(body_kw), do: extract_do_body(body_kw)
  defp extract_def_body([body_kw | _]) when is_list(body_kw), do: extract_do_body(body_kw)
  defp extract_def_body(_), do: nil

  defp head_name_arity({:when, _, [{name, _, args} | _]}), do: {name, arg_count(args)}
  defp head_name_arity({name, _, args}), do: {name, arg_count(args)}
  defp head_name_arity(_), do: {:unknown, 0}

  defp record_def(state, mod, name, arity, visibility, line_num) do
    key = {mod, name, arity}

    fn_def = %{
      module: mod,
      name: name,
      arity: arity,
      visibility: visibility,
      doc_false?: false,
      file: state.file,
      line: line_num
    }

    %{state | defs: Map.put_new(state.defs, key, fn_def)}
  end

  defp arg_count(nil), do: 0
  defp arg_count(args) when is_list(args), do: length(args)
  defp arg_count(_), do: 0

  defp normalize_module(mod) when is_atom(mod), do: AST.module_name(mod)

  # The public API of a context module = public functions defined directly
  # in the root module (e.g., MyApp.Accounts.list_users/0).
  # Sub-modules (MyApp.Accounts.UserQuery.active/0) are NOT part of the public API.
  defp compute_public_api(definitions) do
    definitions
    |> Map.values()
    |> Enum.filter(fn d -> d.visibility == :public and not d.doc_false? end)
    |> Enum.group_by(fn d -> d.module end)
    |> Map.new(fn {mod, defs} ->
      keys = MapSet.new(defs, fn d -> {d.module, d.name, d.arity} end)
      {mod, keys}
    end)
  end
end
