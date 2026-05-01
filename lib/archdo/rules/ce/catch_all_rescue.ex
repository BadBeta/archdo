defmodule Archdo.Rules.CE.CatchAllRescue do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-49. Catch-all `rescue _ ->` clauses
  # swallow specific exceptions the function shouldn't be handling —
  # programming errors (ArgumentError, KeyError, MatchError) get the
  # same treatment as legitimate runtime failures, hiding bugs that
  # should surface immediately.

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "CE-49"

  @impl true
  def description, do: "Catch-all rescue (`rescue _ ->`) without exception type filter"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) or boundary_rescue?(ast) do
      true -> []
      false -> find_catch_all_rescues(file, ast)
    end
  end

  defp boundary_rescue?(ast) do
    AST.contains?(ast, fn
      {:@, _, [{:archdo_boundary_rescue, _, _}]} -> true
      _ -> false
    end)
  end

  defp find_catch_all_rescues(file, ast) do
    {_, lines} =
      Macro.prewalk(ast, [], fn node, acc ->
        {node, acc ++ extract_rescue_clause_lines(node)}
      end)

    Enum.map(lines, &build_diagnostic(file, &1))
  end

  # The `rescue` clause appears in the AST as a keyword pair inside a
  # `def ... rescue ... end` or `try ... rescue ... end` body. With the
  # production parser's literal_encoder, the key is wrapped as
  # `{:__block__, _, [:rescue]}`. Match both shapes.
  defp extract_rescue_clause_lines({{:__block__, _, [:rescue]}, clauses})
       when is_list(clauses) do
    catch_all_lines(clauses)
  end

  defp extract_rescue_clause_lines({:rescue, clauses}) when is_list(clauses) do
    catch_all_lines(clauses)
  end

  defp extract_rescue_clause_lines(_), do: []

  defp catch_all_lines(clauses) do
    Enum.flat_map(clauses, fn
      {:->, meta, [[pattern], _body]} ->
        case catch_all_pattern?(pattern) do
          true -> [AST.line(meta)]
          false -> []
        end

      _ ->
        []
    end)
  end

  # Catch-all patterns: bare `_`, `_e`, or any single underscore-prefixed
  # variable that isn't constrained with `in [Module, ...]`.
  defp catch_all_pattern?({var, _, ctx})
       when is_atom(var) and is_atom(ctx) do
    name = Atom.to_string(var)
    name == "_" or String.starts_with?(name, "_")
  end

  defp catch_all_pattern?(_), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.warning("CE-49",
      title: "Catch-all rescue without exception type filter",
      message: "rescue clause matches anything (`_` or `_var`) — swallows programming errors",
      why:
        "Bare `rescue _ ->` and `rescue _e ->` (no `in [Type1, Type2]` filter) catch " <>
          "ArgumentError / KeyError / MatchError / FunctionClauseError alongside the " <>
          "legitimate runtime failures the author actually wanted to handle. " <>
          "Programming bugs that should surface as crashes get silently swallowed; " <>
          "the supervisor never sees them and the test suite can't catch them.",
      alternatives: [
        Fix.new(
          summary: "Rescue specific exception types",
          detail:
            "Replace `rescue _ -> ...` with `rescue e in [SpecificType, OtherType] -> ...`. " <>
              "Lets programming errors crash to the supervisor while still handling the " <>
              "expected runtime failures.",
          applies_when: "You know which exceptions are legitimate runtime failures."
        ),
        Fix.new(
          summary: "Mark as a process-boundary rescue",
          detail:
            "If the function IS at a process boundary (Plug error renderer, top-level " <>
              "GenServer exit-trap, supervised Task wrapper) where a true last-line " <>
              "catch is the contract, mark with `@archdo_boundary_rescue \"<reason>\"` " <>
              "to suppress this rule.",
          applies_when: "The function is genuinely the last line of defence."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-49"],
      context: %{},
      file: file,
      line: line
    )
  end
end
