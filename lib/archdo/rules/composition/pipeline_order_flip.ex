defmodule Archdo.Rules.Composition.PipelineOrderFlip do
  @moduledoc false
  @behaviour Archdo.Rule

  # 10.3. A function whose @spec input types are a permutation (but
  # not equal) of the return tuple's element types. Such a function
  # cannot be chained back into itself or into any other function
  # expecting the input order — pipelines through it require manual
  # re-shuffling. Pure structural detection; no name heuristics.

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "10.3"

  @impl true
  def description, do: "Function input types appear in return type but in a different order"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_order_flips(file, ast)
    end
  end

  defp find_order_flips(file, ast) do
    spec_signatures = collect_spec_signatures(ast)
    public_keys = public_function_keys(ast)

    Enum.flat_map(spec_signatures, fn {name, arity, arg_types, return_type, meta} ->
      case order_flip?(name, arity, arg_types, return_type, public_keys) do
        true -> [build_diagnostic(file, name, arity, meta)]
        false -> []
      end
    end)
  end

  defp public_function_keys(ast) do
    ast
    |> AST.extract_functions(:public)
    |> MapSet.new(fn {name, arity, _meta, _args, _body} -> {name, arity} end)
  end

  defp collect_spec_signatures(ast) do
    {_, list} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{:spec, meta, [{:"::", _, [{name, _, args}, return]}]}]} = node, acc
        when is_atom(name) and is_list(args) ->
          {node, [{name, length(args), args, return, meta} | acc]}

        node, acc ->
          {node, acc}
      end)

    list
  end

  defp order_flip?(name, arity, arg_types, return_type, public_keys) do
    MapSet.member?(public_keys, {name, arity}) and
      arity >= 2 and
      tuple_permutation_mismatch?(arg_types, return_type)
  end

  defp tuple_permutation_mismatch?(arg_types, return_type) do
    case tuple_elements(return_type) do
      nil -> false
      elements -> permutation_but_not_equal?(arg_types, elements)
    end
  end

  defp tuple_elements({:{}, _, elements}) when is_list(elements), do: elements
  defp tuple_elements({a, b}), do: [a, b]
  defp tuple_elements(_), do: nil

  defp permutation_but_not_equal?(args, returns) do
    arg_keys = Enum.map(args, &type_key/1)
    return_keys = Enum.map(returns, &type_key/1)

    length(arg_keys) == length(return_keys) and
      arg_keys != return_keys and
      Enum.sort(arg_keys) == Enum.sort(return_keys)
  end

  # Strip metadata so types compare structurally. Two AST nodes for the
  # same type may differ only in line/column metadata.
  defp type_key(ast) do
    ast
    |> Macro.prewalk(fn
      {form, meta, args} when is_list(meta) -> {form, [], args}
      other -> other
    end)
  end

  defp build_diagnostic(file, name, arity, meta) do
    Diagnostic.info("10.3",
      title: "Function output flips the order of input types",
      message:
        "#{name}/#{arity} returns the same types it accepts but in a different order — " <>
          "callers cannot pipe its result back into a function expecting the original order",
      why:
        "Pipelines compose by feeding one function's output into the next function's first " <>
          "argument. When a function's @spec says it takes (T1, T2) and returns {T2, T1}, " <>
          "the result cannot pipe into anything expecting T1 first. The same function cannot " <>
          "even chain into another instance of itself. This blocks composition without " <>
          "a clear domain reason for the swap.",
      alternatives: [
        Fix.new(
          summary: "Match output order to input order",
          detail:
            "Return {T1, T2} if the inputs were (T1, T2). Subsequent pipeline steps can then " <>
              "consume the result without unwrapping and re-shuffling.",
          applies_when: "The order swap is incidental, not part of the function's contract."
        ),
        Fix.new(
          summary: "Document the contract if the swap is intentional",
          detail:
            "If the swap is the function's purpose (e.g., a `swap/2`), the rule is a false " <>
              "positive — add a moduledoc note or `@archdo_arg_order_ok` marker to silence it.",
          applies_when: "The flipped output IS the function's domain meaning."
        )
      ],
      references: [],
      context: %{function: "#{name}/#{arity}"},
      file: file,
      line: AST.line(meta)
    )
  end
end
