defmodule Archdo.Rules.Module.VerboseOkUnwrap do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.40"

  @impl true
  def description,
    do: "Verbose ok/error unwrap — case with ok/error that swallows error and returns nil"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_verbose_unwraps(file, ast)
    end
  end

  defp find_verbose_unwraps(file, ast) do
    List.flatten([
      find_swallow_error_nil(file, ast),
      find_single_ok_clause(file, ast)
    ])
  end

  # Detect: case expr do {:ok, val} -> val; {:error, _} -> nil end
  defp find_swallow_error_nil(file, ast) do
    Enum.map(
      AST.find_all(ast, fn
        {:case, _, [_expr, clauses_kw]} ->
          clauses = extract_clauses(clauses_kw)

          case length(clauses) == 2 do
            true -> has_ok_extract?(clauses) and has_error_nil?(clauses)
            false -> false
          end

        _ ->
          false
      end),
      fn {:case, meta, _} ->
        build_diagnostic(file, AST.line(meta), :swallow_error_nil)
      end
    )
  end

  # Detect: case expr do {:ok, val} -> val end (no error clause)
  defp find_single_ok_clause(file, ast) do
    Enum.map(
      AST.find_all(ast, fn
        {:case, _, [_expr, clauses_kw]} ->
          clauses = extract_clauses(clauses_kw)

          case length(clauses) == 1 do
            true -> has_ok_extract?(clauses)
            false -> false
          end

        _ ->
          false
      end),
      fn {:case, meta, _} ->
        build_diagnostic(file, AST.line(meta), :single_ok_clause)
      end
    )
  end

  # Extract clauses from the keyword body of a case expression.
  # With literal_encoder, it's [{__block__(:do), [clause1, clause2]}]
  defp extract_clauses([{_, clauses}]) when is_list(clauses), do: clauses
  defp extract_clauses(do: clauses) when is_list(clauses), do: clauses
  defp extract_clauses(_), do: []

  # Check if clauses contain {:ok, var} -> var (extracting the ok value)
  # With literal_encoder, {:ok, val} is a 2-tuple encoded as:
  # {:__block__, meta, [{{:__block__, _, [:ok]}, {var, _, ctx}}]}
  defp has_ok_extract?(clauses) do
    Enum.any?(clauses, fn
      # {:ok, var} -> var with literal_encoder (2-tuple wrapped in __block__)
      {:->, _,
       [
         [{:__block__, _, [{{:__block__, _, [:ok]}, {var, _, ctx}}]}],
         {var, _, ctx}
       ]}
      when is_atom(var) and is_atom(ctx) ->
        true

      # {:ok, var} -> var without literal_encoder
      {:->, _, [[{:ok, {var, _, ctx}}], {var, _, ctx}]}
      when is_atom(var) and is_atom(ctx) ->
        true

      # 3+ element tuple {:ok, val} encoded as {:{}, _, [:ok, var]}
      {:->, _,
       [
         [{:{}, _, [{:__block__, _, [:ok]}, {var, _, ctx}]}],
         {var, _, ctx}
       ]}
      when is_atom(var) and is_atom(ctx) ->
        true

      _ ->
        false
    end)
  end

  # Check if clauses contain {:error, _} -> nil
  defp has_error_nil?(clauses) do
    Enum.any?(clauses, fn
      # {:error, _} -> nil with literal_encoder (2-tuple wrapped in __block__)
      {:->, _,
       [
         [{:__block__, _, [{{:__block__, _, [:error]}, {:_, _, _}}]}],
         {:__block__, _, [nil]}
       ]} ->
        true

      # {:error, _} -> nil without __block__ on nil
      {:->, _,
       [
         [{:__block__, _, [{{:__block__, _, [:error]}, {:_, _, _}}]}],
         nil
       ]} ->
        true

      # Without literal_encoder
      {:->, _, [[{:error, {:_, _, _}}], nil]} ->
        true

      {:->, _, [[{:error, {:_, _, _}}], {:__block__, _, [nil]}]} ->
        true

      # 3+ element tuple form
      {:->, _,
       [
         [{:{}, _, [{:__block__, _, [:error]}, {:_, _, _}]}],
         {:__block__, _, [nil]}
       ]} ->
        true

      {:->, _,
       [
         [{:{}, _, [{:__block__, _, [:error]}, {:_, _, _}]}],
         nil
       ]} ->
        true

      _ ->
        false
    end)
  end

  # --- Diagnostics ---

  defp build_diagnostic(file, line, :swallow_error_nil) do
    Diagnostic.info("6.40",
      title: "Verbose ok/error unwrap: swallow error, return nil",
      message:
        "case with {:ok, val} -> val; {:error, _} -> nil — silently discards the error reason",
      why:
        "This pattern swallows error information, making debugging harder. " <>
          "If the error is expected and nil is the desired fallback, make that intent " <>
          "explicit. If the error is unexpected, it should propagate.",
      alternatives: [
        Fix.new(
          summary: "Use with/else or a dedicated helper",
          detail:
            "Consider `with {:ok, val} <- expr do val else _ -> nil end`, " <>
              "or propagate the error with `{:ok, val} = expr`.",
          applies_when: "A case expression matches {:ok, val} -> val and {:error, _} -> nil."
        )
      ],
      file: file,
      line: line
    )
  end

  defp build_diagnostic(file, line, :single_ok_clause) do
    Diagnostic.info("6.40",
      title: "Verbose ok/error unwrap: case with only :ok clause",
      message:
        "case with only {:ok, val} -> val — will crash with CaseClauseError on {:error, _}",
      why:
        "A case that only handles {:ok, val} will raise CaseClauseError if the " <>
          "expression returns {:error, _}. If crashing is intended, use " <>
          "`{:ok, val} = expr` which is more explicit about the assertion.",
      alternatives: [
        Fix.new(
          summary: "Use pattern match assertion instead",
          detail:
            "`{:ok, val} = expr` is more idiomatic for asserting success. " <>
              "Or add an {:error, _} clause to handle failures.",
          applies_when: "A case expression has only one clause matching {:ok, val}."
        )
      ],
      file: file,
      line: line
    )
  end
end
