defmodule Archdo.Rules.Module.ShortCircuitOverAccumulating do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  # Function-name prefixes that signal accumulating-validation territory.
  # Accumulating means: collect ALL errors and report them, not stop at
  # the first failure. `with` short-circuits on first failure — wrong shape.
  @accumulating_prefixes ~w(validate_ import_ bulk_ check_)

  @impl true
  def id, do: "6.95"

  @impl true
  def description,
    do: "Short-circuit `with` chain in an accumulating-validation function"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_accumulating_with_chains(file, ast)
    end
  end

  defp find_accumulating_with_chains(file, ast) do
    ast
    |> AST.extract_functions(:all)
    |> Enum.filter(fn {name, _arity, _meta, _args, _body} ->
      accumulating_name?(name)
    end)
    |> Enum.flat_map(fn {name, arity, meta, _args, body} ->
      body
      |> accumulating_with_chains()
      |> Enum.map(fn arrow_count ->
        build_diagnostic(file, AST.line(meta), name, arity, arrow_count)
      end)
    end)
  end

  defp accumulating_with_chains(body) do
    body
    |> AST.find_all(fn
      {:with, _, _} -> true
      _ -> false
    end)
    |> Enum.flat_map(&analyze_with/1)
  end

  defp analyze_with({:with, _, clauses}) when is_list(clauses) do
    arrow_clauses = Enum.filter(clauses, &arrow_clause?/1)
    arrow_count = length(arrow_clauses)
    bound = bound_var_set(arrow_clauses)
    used = used_bound_count(success_body(clauses), bound)
    qualifies?(arrow_count, used, arrow_count)
  end

  defp analyze_with(_), do: []

  # Flag only when there are 2+ `<-` clauses AND the success body uses 2+
  # of the bound names — the strong signal of "combine independent results."
  defp qualifies?(arrow_count, used, count) when arrow_count >= 2 and used >= 2,
    do: [count]

  defp qualifies?(_arrow_count, _used, _count), do: []

  defp arrow_clause?({:<-, _, _}), do: true
  defp arrow_clause?(_), do: false

  defp bound_var_set(arrow_clauses) do
    arrow_clauses
    |> Enum.flat_map(&lhs_vars/1)
    |> MapSet.new()
  end

  defp lhs_vars({:<-, _, [lhs, _]}), do: collect_simple_vars(lhs)
  defp lhs_vars(_), do: []

  defp collect_simple_vars(ast) do
    {_, vars} =
      Macro.prewalk(ast, [], fn
        {name, _meta, ctx} = node, acc when is_atom(name) and is_atom(ctx) ->
          {node, accumulate_var(name, acc)}

        node, acc ->
          {node, acc}
      end)

    vars
  end

  defp accumulate_var(name, acc) do
    case Atom.to_string(name) do
      "_" <> _ -> acc
      _ -> [name | acc]
    end
  end

  defp success_body(clauses) do
    case List.last(clauses) do
      kw when is_list(kw) -> Keyword.get(kw, :do)
      _ -> nil
    end
  end

  defp used_bound_count(nil, _bound), do: 0

  defp used_bound_count(body, bound) do
    {_, used} =
      Macro.prewalk(body, MapSet.new(), fn
        {name, _meta, ctx} = node, acc when is_atom(name) and is_atom(ctx) ->
          {node, mark_used(name, bound, acc)}

        node, acc ->
          {node, acc}
      end)

    MapSet.size(used)
  end

  defp mark_used(name, bound, acc) do
    case MapSet.member?(bound, name) do
      true -> MapSet.put(acc, name)
      false -> acc
    end
  end

  defp accumulating_name?(name) when is_atom(name) do
    str = Atom.to_string(name)
    Enum.any?(@accumulating_prefixes, &String.starts_with?(str, &1))
  end

  defp accumulating_name?(_), do: false

  defp build_diagnostic(file, line, name, arity, arrow_count) do
    Diagnostic.info("6.95",
      title: "Short-circuit `with` in accumulating-flavored function",
      message:
        "#{name}/#{arity} is named like an accumulating validator " <>
          "(`validate_*`/`import_*`/`bulk_*`/`check_*`) but its body uses " <>
          "a #{arrow_count}-step `with` chain that short-circuits on the " <>
          "first error.",
      why:
        "`with` is railway-style: it stops at the first failure and returns " <>
          "that failure unchanged. That's correct when later steps depend on " <>
          "earlier ones (a sequential pipeline). But validation, import, and " <>
          "bulk-creation flows usually want to report ALL errors so the user " <>
          "can fix them in one round-trip. With short-circuit, the user fixes " <>
          "field 1, resubmits, sees field 2's error, fixes that, resubmits, " <>
          "sees field 3 — slow and frustrating. The accumulating shape is a " <>
          "reduce that builds an error list, returning `{:ok, value}` if " <>
          "empty or `{:error, errors}` otherwise.",
      alternatives: [
        Fix.new(
          summary: "Replace `with` with an error-accumulating reduce",
          detail:
            "Run each independent validator, collect errors, and return all " <>
              "of them at once.",
          example: """
          ```elixir
          # before
          with {:ok, email} <- validate_email(p),
               {:ok, password} <- validate_password(p),
               {:ok, age} <- validate_age(p) do
            {:ok, %{email: email, password: password, age: age}}
          end

          # after
          [&validate_email/1, &validate_password/1, &validate_age/1]
          |> Enum.reduce({%{}, []}, fn validator, {acc, errs} ->
            case validator.(p) do
              {:ok, {key, val}} -> {Map.put(acc, key, val), errs}
              {:error, e} -> {acc, [e | errs]}
            end
          end)
          |> case do
            {fields, []} -> {:ok, fields}
            {_, errs} -> {:error, Enum.reverse(errs)}
          end
          ```
          """,
          applies_when:
            "The validation steps are independent — each can be run without " <>
              "the others' results."
        ),
        Fix.new(
          summary: "Keep `with` if steps are sequentially dependent",
          detail:
            "If step N genuinely needs step N-1's success value (e.g., " <>
              "`fetch_user` then `fetch_user's_orders`), `with` is correct " <>
              "and this finding is a false positive. Suppress with " <>
              "`# archdo:disable-next-line 6.95` or rename the function to " <>
              "remove the accumulating prefix.",
          applies_when:
            "Each step's success value feeds the next step — the pipeline " <>
              "cannot continue without the prior result."
        )
      ],
      context: %{function: "#{name}/#{arity}", arrow_count: arrow_count},
      file: file,
      line: line
    )
  end
end
