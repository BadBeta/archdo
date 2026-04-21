defmodule Archdo.Rules.Module.RescueForExpected do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.14"

  @impl true
  def description, do: "try/rescue used for expected failures — use ok/error tuples or non-bang functions"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      find_rescue_for_expected(file, ast)
    end
  end

  defp find_rescue_for_expected(file, ast) do
    ast
    |> AST.find_all(fn
      {:try, _, [[do: try_body, rescue: rescue_clauses]]} ->
        has_bang_in_try?(try_body) and catches_specific_exception?(rescue_clauses)

      {:try, _, [[do: try_body] ++ rest]} when is_list(rest) ->
        case Keyword.get(rest, :rescue) do
          nil -> false
          clauses -> has_bang_in_try?(try_body) and catches_specific_exception?(clauses)
        end

      _ ->
        false
    end)
    |> Enum.map(fn {:try, meta, _} ->
      build_diagnostic(file, AST.line(meta))
    end)
  end

  defp has_bang_in_try?(body) do
    AST.contains?(body, fn
      # Remote call: Module.func!(args)
      {{:., _, [_, func]}, _, _} when is_atom(func) ->
        func
        |> Atom.to_string()
        |> String.ends_with?("!")

      # Local call: func!(args)
      {func, _, args} when is_atom(func) and is_list(args) ->
        func
        |> Atom.to_string()
        |> String.ends_with?("!")

      _ ->
        false
    end)
  end

  defp catches_specific_exception?(clauses) when is_list(clauses) do
    Enum.any?(clauses, fn
      # rescue e in [SpecificError] -> ...
      {:->, _, [[{:in, _, [_, exceptions]}], _body]} ->
        is_list(exceptions) or match?({:__aliases__, _, _}, exceptions)

      # rescue SpecificError -> ...
      {:->, _, [[{:__aliases__, _, _}], _body]} ->
        true

      # rescue _ -> ... (wildcard — also a smell, already caught by 6.9)
      _ ->
        true
    end)
  end

  defp catches_specific_exception?(_), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.warning("6.14",
      title: "try/rescue for expected failure",
      message:
        "try/rescue wraps a bang function — use the non-bang variant with ok/error tuples instead",
      why:
        "When a bang function (get!, decode!, insert!) is wrapped in try/rescue, the code is " <>
          "converting an exception back into a value — undoing what the bang function was designed " <>
          "to do. The non-bang variant already returns {:ok, _}/{:error, _} without the exception " <>
          "overhead. The try/rescue pattern also catches more than intended: a bug in the try body " <>
          "that raises the same exception type is silently swallowed.",
      alternatives: [
        Fix.new(
          summary: "Use the non-bang function with pattern matching",
          detail:
            "Replace `try do Repo.get!(User, id) rescue Ecto.NoResultsError -> nil end` with " <>
              "`Repo.get(User, id)` which returns nil on not-found. For Ash, replace `Domain.get!(id)` " <>
              "with `Domain.get(id)` which returns `{:ok, record}` or `{:error, error}`.",
          example: """
          ```elixir
          # BAD — exception round-trip
          try do
            user = Repo.get!(User, id)
            {:ok, user}
          rescue
            Ecto.NoResultsError -> {:error, :not_found}
          end

          # GOOD — non-bang returns what you need
          case Repo.get(User, id) do
            nil -> {:error, :not_found}
            user -> {:ok, user}
          end
          ```
          """,
          applies_when: "A non-bang alternative exists (almost always does)."
        ),
        Fix.new(
          summary: "Use `with` to chain failable operations",
          detail:
            "If multiple operations can fail, chain them with `with` and ok/error tuples " <>
              "instead of nesting try/rescue blocks.",
          applies_when: "Multiple failable operations are chained."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.14"],
      context: %{},
      file: file,
      line: line
    )
  end
end
