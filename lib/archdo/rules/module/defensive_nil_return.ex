defmodule Archdo.Rules.Module.DefensiveNilReturn do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.39"

  @impl true
  def description, do: "Catch-all case clause returns bare nil"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_defensive_nils(file, ast)
    end
  end

  defp find_defensive_nils(file, ast) do
    {_, diagnostics} =
      Macro.prewalk(ast, [], fn
        {:case, meta, [_expr, [do: clauses]]} = node, acc when is_list(clauses) ->
          case defensive_nil_clause?(clauses) do
            true ->
              {node, [build_diagnostic(file, AST.line(meta)) | acc]}

            false ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(diagnostics)
  end

  defp defensive_nil_clause?(clauses) when length(clauses) < 3, do: false

  defp defensive_nil_clause?(clauses) do
    last_clause = List.last(clauses)
    catch_all_returning_nil?(last_clause)
  end

  # Match: _ -> nil (where nil may be wrapped in __block__)
  defp catch_all_returning_nil?({:->, _, [[pattern], body]}) do
    AST.catch_all_pattern?(pattern) and bare_nil?(body)
  end

  defp catch_all_returning_nil?(_), do: false

  defp bare_nil?({:__block__, _, [nil]}), do: true
  defp bare_nil?(nil), do: true
  defp bare_nil?(_), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.39",
      title: "Defensive nil return",
      message:
        "case has a catch-all clause (`_ -> nil`) — if all cases are handled, " <>
          "this hides match errors instead of surfacing them",
      why:
        "Adding `_ -> nil` as a safety net in case statements is a common LLM pattern. " <>
          "When the code already handles all expected cases, the catch-all silently swallows " <>
          "unexpected values instead of crashing with a clear MatchError. " <>
          "In Elixir, letting unexpected patterns crash is preferable — it surfaces bugs " <>
          "immediately and supervisors handle recovery.",
      alternatives: [
        Fix.new(
          summary: "Remove the catch-all clause",
          detail:
            "If all expected patterns are handled, remove `_ -> nil` and let " <>
              "unexpected values raise a MatchError (fail-fast).",
          applies_when: "All legitimate cases are already covered by specific clauses."
        ),
        Fix.new(
          summary: "Return a meaningful error instead",
          detail:
            "Replace `_ -> nil` with `_ -> {:error, :unexpected_value}` or " <>
              "`other -> raise \"unexpected: \#{inspect(other)}\"` for visibility.",
          applies_when: "The catch-all handles a real possibility that needs a response."
        ),
        Fix.new(
          summary: "Log the unexpected value",
          detail:
            "Replace with `other -> Logger.warning(\"unexpected: \#{inspect(other)}\"); nil` " <>
              "to maintain behavior but gain observability.",
          applies_when: "You need the nil return but want to know when it happens."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.39"],
      context: %{},
      file: file,
      line: line
    )
  end
end
