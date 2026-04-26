defmodule Archdo.Rules.Module.RedundantGuardRecheck do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.36"

  @impl true
  def description,
    do: "Redundant guard recheck — type already guaranteed by pattern match or guard"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_redundant_rechecks(file, ast)
    end
  end

  defp find_redundant_rechecks(file, ast) do
    fns = extract_function_defs(ast)
    Enum.flat_map(fns, &check_function(file, &1))
  end

  # Extract function definitions, properly handling guarded and unguarded forms.
  # Returns [{meta, params, guard | nil, body}]
  defp extract_function_defs(ast) do
    {_, fns} =
      Macro.prewalk(ast, [], fn
        # def foo(args) when guard do body end
        {def_kind, meta, [{:when, _, [func_call, guard]}, body_kw]} = node, acc
        when def_kind in [:def, :defp] ->
          {_name, _meta, params} = func_call
          body = extract_body(body_kw)
          {node, [{meta, params || [], guard, body} | acc]}

        # def foo(args) do body end (no guard)
        {def_kind, meta, [{func_name, _, params}, body_kw]} = node, acc
        when def_kind in [:def, :defp] and is_atom(func_name) ->
          body = extract_body(body_kw)
          {node, [{meta, params || [], nil, body} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(fns)
  end

  defp extract_body([{_, body}]), do: body
  defp extract_body(body), do: body

  defp check_function(file, {meta, params, guard, body}) do
    # Step 1: Extract type guarantees from patterns
    pattern_guarantees = extract_pattern_guarantees(params)

    # Step 2: Extract type guarantees from guards
    guard_guarantees = extract_guard_guarantees(guard)

    all_guarantees = Map.merge(pattern_guarantees, guard_guarantees)

    case map_size(all_guarantees) do
      0 ->
        []

      _ ->
        # Step 3: Walk body looking for redundant is_* checks on guaranteed vars
        find_redundant_checks_in_body(file, AST.line(meta), body, all_guarantees)
    end
  end

  # Extract what the pattern match guarantees about each variable.
  defp extract_pattern_guarantees(params) when is_list(params) do
    Enum.reduce(params, %{}, fn arg, acc ->
      extract_guarantees_from_pattern(arg, acc)
    end)
  end

  defp extract_pattern_guarantees(_), do: %{}

  # pattern = var (e.g., %{} = x)
  defp extract_guarantees_from_pattern({:=, _, [pattern, {var, _, ctx}]}, acc)
       when is_atom(var) and is_atom(ctx) and var != :_ do
    case pattern_type(pattern) do
      nil -> acc
      type -> Map.put(acc, var, type)
    end
  end

  # var = pattern (e.g., x = %{})
  defp extract_guarantees_from_pattern({:=, _, [{var, _, ctx}, pattern]}, acc)
       when is_atom(var) and is_atom(ctx) and var != :_ do
    case pattern_type(pattern) do
      nil -> acc
      type -> Map.put(acc, var, type)
    end
  end

  defp extract_guarantees_from_pattern(_, acc), do: acc

  # Determine what type a pattern guarantees
  defp pattern_type({:%{}, _, _}), do: :map
  defp pattern_type({:%, _, _}), do: :map
  # [_ | _] with literal_encoder: {:__block__, _, [[{:|, _, _}]]}
  defp pattern_type({:__block__, _, [[{:|, _, _}]]}), do: :list
  defp pattern_type({:__block__, _, [[]]}), do: :list
  # Without literal_encoder
  defp pattern_type([{:|, _, _}]), do: :list
  defp pattern_type([]), do: :list
  # Binary pattern
  defp pattern_type({:<<>>, _, _}), do: :binary
  defp pattern_type(_), do: nil

  # Extract guarantees from a guard expression
  defp extract_guard_guarantees(nil), do: %{}

  defp extract_guard_guarantees(guard) do
    extract_guards(guard, %{})
  end

  defp extract_guards({:and, _, [left, right]}, acc) do
    acc = extract_guards(left, acc)
    extract_guards(right, acc)
  end

  defp extract_guards({guard_fn, _, [{var, _, ctx}]}, acc)
       when is_atom(var) and is_atom(ctx) do
    case guard_to_type(guard_fn) do
      nil -> acc
      type -> Map.put(acc, var, type)
    end
  end

  defp extract_guards(_, acc), do: acc

  @guard_type_map %{
    is_map: :map,
    is_list: :list,
    is_binary: :binary,
    is_integer: :integer,
    is_float: :float,
    is_number: :number,
    is_atom: :atom,
    is_tuple: :tuple,
    is_boolean: :boolean,
    is_pid: :pid
  }

  defp guard_to_type(guard_fn), do: Map.get(@guard_type_map, guard_fn)

  # Walk the function body looking for is_* calls on variables we already know the type of
  defp find_redundant_checks_in_body(file, fn_line, body, guarantees) do
    body
    |> AST.find_all(fn
      {guard_fn, _, [{var, _, ctx}]}
      when is_atom(guard_fn) and is_atom(var) and is_atom(ctx) ->
        case {guard_to_type(guard_fn), Map.get(guarantees, var)} do
          {type, type} when type != nil -> true
          _ -> false
        end

      _ ->
        false
    end)
    |> Enum.map(fn {guard_fn, meta, [{var, _, _}]} ->
      line = AST.line(meta)

      actual_line =
        case line > 0 do
          true -> line
          false -> fn_line
        end

      build_diagnostic(file, actual_line, %{
        guard: guard_fn,
        variable: var,
        guaranteed_by: Map.get(guarantees, var)
      })
    end)
  end

  defp build_diagnostic(file, line, %{guard: guard, variable: var, guaranteed_by: type}) do
    Diagnostic.info("6.36",
      title: "Redundant guard recheck",
      message:
        "#{guard}(#{var}) in body is redundant — #{var} is already guaranteed " <>
          "to be #{type} by the function head pattern or guard",
      why:
        "When a function head pattern matches a map (%{}), list ([_ | _]), or binary (<<>>), " <>
          "or a guard clause uses is_map/is_list/is_binary, the variable's type is already " <>
          "proven. Rechecking with is_* in the body is dead code that clutters the logic.",
      alternatives: [
        Fix.new(
          summary: "Remove the redundant #{guard}(#{var}) check",
          detail:
            "The pattern match or guard already guarantees the type. " <>
              "Remove the is_* check and use the variable directly.",
          applies_when: "The function head already constrains the variable's type."
        )
      ],
      file: file,
      line: line
    )
  end
end
