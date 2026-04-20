defmodule Archdo.Rules.Module.UnreachableClause do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.35"

  @impl true
  def description, do: "Catch-all clause before specific clauses makes later clauses unreachable"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_unreachable(file, ast)
    end
  end

  defp find_unreachable(file, ast) do
    {_, diagnostics} =
      Macro.prewalk(ast, [], fn
        {:case, meta, [_expr, [do: clauses]]} = node, acc when is_list(clauses) ->
          {node, check_case_clauses(file, meta, clauses, acc)}

        {:cond, meta, [[do: clauses]]} = node, acc when is_list(clauses) ->
          {node, check_cond_clauses(file, meta, clauses, acc)}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(diagnostics)
  end

  defp check_case_clauses(file, case_meta, clauses, acc) do
    clauses
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {{:->, _, [[pattern | _guards], _body]}, index}, acc ->
      case catch_all_pattern?(pattern) and index < length(clauses) - 1 do
        true ->
          line = AST.line(case_meta)
          [build_case_diagnostic(file, line) | acc]

        false ->
          acc
      end
    end)
  end

  defp check_cond_clauses(file, cond_meta, clauses, acc) do
    clauses
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {{:->, _, [[condition], _body]}, index}, acc ->
      case literal_true?(condition) and index < length(clauses) - 1 do
        true ->
          line = AST.line(cond_meta)
          [build_cond_diagnostic(file, line) | acc]

        false ->
          acc
      end
    end)
  end

  # Catch-all patterns: `_` or a bare variable (no destructuring, no pinning)
  defp catch_all_pattern?({:_, _, _}), do: true

  defp catch_all_pattern?({name, _, context})
       when is_atom(name) and is_atom(context) and name != :_ do
    not String.starts_with?(Atom.to_string(name), "_")
  end

  defp catch_all_pattern?(_), do: false

  # Match `true` which may be wrapped in __block__ by literal_encoder
  defp literal_true?({:__block__, _, [true]}), do: true
  defp literal_true?(true), do: true
  defp literal_true?(_), do: false

  defp build_case_diagnostic(file, line) do
    Diagnostic.warning("6.35",
      title: "Unreachable clause",
      message:
        "case has a catch-all pattern (`_` or bare variable) before more specific clauses — " <>
          "subsequent clauses will never match",
      why:
        "A catch-all pattern matches everything. When it appears before specific patterns, " <>
          "the specific patterns become dead code — they can never execute. This is usually " <>
          "a clause ordering mistake. Move the catch-all to the last position.",
      alternatives: [
        Fix.new(
          summary: "Move the catch-all clause to the end",
          detail:
            "Reorder the clauses so the catch-all (`_` or bare variable) is the last clause.",
          applies_when: "The catch-all is a default/fallback handler."
        ),
        Fix.new(
          summary: "Replace with a specific pattern",
          detail:
            "If the catch-all should only match certain values, replace it with a specific pattern.",
          applies_when: "The catch-all is too broad and should be narrowed."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.35"],
      context: %{construct: :case},
      file: file,
      line: line
    )
  end

  defp build_cond_diagnostic(file, line) do
    Diagnostic.warning("6.35",
      title: "Unreachable clause",
      message:
        "cond has `true ->` before the last clause — subsequent clauses will never execute",
      why:
        "In a cond expression, `true ->` always matches. When it appears before other clauses, " <>
          "those clauses become dead code. The idiomatic pattern is `true ->` as the LAST clause " <>
          "(like a default/else branch).",
      alternatives: [
        Fix.new(
          summary: "Move `true ->` to the last clause",
          detail:
            "Reorder clauses so `true ->` is the final fallback, not an early exit.",
          applies_when: "The true clause is meant to be the default handler."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.35"],
      context: %{construct: :cond},
      file: file,
      line: line
    )
  end
end
