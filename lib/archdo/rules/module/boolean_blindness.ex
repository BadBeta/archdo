defmodule Archdo.Rules.Module.BooleanBlindness do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @failable_prefixes ~w(validate check verify authorize authenticate confirm ensure)

  @impl true
  def id, do: "6.45"

  @impl true
  def description, do: "Public function returns bare boolean for failable operation — use {:ok, _}/{:error, reason}"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_boolean_blindness(file, ast)
    end
  end

  defp find_boolean_blindness(file, ast) do
    ast
    |> AST.extract_functions(:public)
    |> Enum.filter(fn {name, _, _, _, _} -> is_atom(name) end)
    |> Enum.flat_map(fn {name, arity, meta, _args, body} ->
      name_str = Atom.to_string(name)

      case {predicate?(name_str), failable_name?(name_str), bare_boolean_returns?(body)} do
        {false, true, true} ->
          [build_diagnostic(file, AST.line(meta), name, arity)]

        _ ->
          []
      end
    end)
  end

  defp predicate?(name_str), do: String.ends_with?(name_str, "?")

  defp failable_name?(name_str) do
    Enum.any?(@failable_prefixes, fn prefix ->
      String.starts_with?(name_str, prefix)
    end)
  end

  # Check if ALL return paths return bare true or false (no tagged tuples).
  # We collect all terminal expressions and check they are all booleans.
  defp bare_boolean_returns?(body) do
    returns = collect_returns(body)

    case returns do
      [] ->
        false

      returns ->
        has_true = Enum.any?(returns, &(&1 == :true_return))
        has_false = Enum.any?(returns, &(&1 == :false_return))
        has_other = Enum.any?(returns, &(&1 == :other_return))
        has_true and has_false and not has_other
    end
  end

  # Collect return value types from the function body.
  defp collect_returns(nil), do: []

  defp collect_returns([{_key, body}]) do
    collect_returns(body)
  end

  defp collect_returns([{_key, body} | rest]) when rest != [] do
    collect_returns(body) ++ collect_returns(rest)
  end

  defp collect_returns({:__block__, _, exprs}) when is_list(exprs) do
    case List.last(exprs) do
      nil -> []
      last -> collect_returns(last)
    end
  end

  defp collect_returns({:case, _, [_expr | [[do: clauses]]]}), do: collect_from_clauses(clauses)

  defp collect_returns({:cond, _, [[do: clauses]]}), do: collect_from_clauses(clauses)

  defp collect_returns({:if, _, [_cond, [do: do_body, else: else_body]]}) do
    collect_returns(do_body) ++ collect_returns(else_body)
  end

  defp collect_returns({:if, _, [_cond, [do: do_body]]}) do
    collect_returns(do_body) ++ [:other_return]
  end

  defp collect_returns(true), do: [:true_return]
  defp collect_returns(false), do: [:false_return]
  defp collect_returns({:__block__, _, [true]}), do: [:true_return]
  defp collect_returns({:__block__, _, [false]}), do: [:false_return]

  # Tagged tuples like {:ok, _} or {:error, _} — not bare boolean
  defp collect_returns({:{}, _, _}), do: [:other_return]
  defp collect_returns({_, _}), do: [:other_return]

  defp collect_returns(_), do: [:other_return]

  defp collect_from_clauses(clauses) when is_list(clauses) do
    Enum.flat_map(clauses, fn {:->, _, [_pattern, body]} ->
      collect_returns(body)
    end)
  end

  defp collect_from_clauses(_), do: [:other_return]

  defp build_diagnostic(file, line, name, arity) do
    Diagnostic.info("6.45",
      title: "Boolean blindness: #{name}/#{arity}",
      message:
        "#{name}/#{arity} returns bare true/false but the name suggests a failable operation — " <>
          "callers can't know WHY it failed",
      why:
        "When a function named `#{name}` returns `false`, the caller has no information " <>
          "about what went wrong. Returning `{:ok, result}` or `{:error, reason}` lets " <>
          "callers handle specific failure cases. Reserve bare booleans for predicates (functions " <>
          "ending with `?`).",
      alternatives: [
        Fix.new(
          summary: "Return {:ok, _}/{:error, reason} instead of true/false",
          detail:
            "Replace `true` with `{:ok, result}` and `false` with `{:error, :specific_reason}`. " <>
              "This gives callers actionable error information.",
          applies_when: "The function performs validation, authorization, or any failable operation."
        ),
        Fix.new(
          summary: "Rename to a predicate if it truly is a boolean check",
          detail:
            "If the function genuinely answers a yes/no question with no failure mode, " <>
              "rename it to `#{name}?/#{arity}` to signal that bare boolean is intentional.",
          applies_when: "The function is a pure check with no meaningful failure reasons."
        )
      ],
      file: file,
      line: line
    )
  end
end
