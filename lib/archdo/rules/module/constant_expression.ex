defmodule Archdo.Rules.Module.ConstantExpression do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.42"

  @impl true
  def description, do: "Conditional with constant/literal condition"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_constant_conditions(file, ast)
    end
  end

  defp find_constant_conditions(file, ast) do
    {_, diagnostics} =
      Macro.prewalk(ast, [], fn
        # if true do ... end / if false do ... end
        {:if, meta, [condition | _]} = node, acc ->
          case constant_boolean?(condition) do
            true ->
              {node, [build_if_diagnostic(file, AST.line(meta), condition) | acc]}

            false ->
              {node, acc}
          end

        # cond do true -> ... ; more_clauses end (true as FIRST clause with more after)
        {:cond, meta, [[do: [{:->, _, [[condition], _body]} | more]]]} = node, acc
        when is_list(more) and more != [] ->
          case literal_true?(condition) do
            true ->
              {node, [build_cond_diagnostic(file, AST.line(meta)) | acc]}

            false ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(diagnostics)
  end

  defp constant_boolean?({:__block__, _, [true]}), do: true
  defp constant_boolean?({:__block__, _, [false]}), do: true
  defp constant_boolean?(true), do: true
  defp constant_boolean?(false), do: true
  defp constant_boolean?(_), do: false

  defp literal_true?({:__block__, _, [true]}), do: true
  defp literal_true?(true), do: true
  defp literal_true?(_), do: false

  defp build_if_diagnostic(file, line, condition) do
    value = AST.unwrap_literal(condition)

    Diagnostic.info("6.42",
      title: "Constant expression",
      message: "if #{value} — condition is always #{value}, branch is #{if_branch_desc(value)}",
      why:
        "A conditional with a constant condition is dead code. The branch is always taken " <>
          "(or never taken), making the conditional pointless. This often indicates leftover " <>
          "debugging code, a feature flag that was resolved, or an LLM generation artifact.",
      alternatives: [
        Fix.new(
          summary: "Remove the conditional",
          detail:
            "Replace `if #{value} do body end` with just the body (if true) or remove entirely (if false).",
          applies_when: "The constant condition is not intentional."
        ),
        Fix.new(
          summary: "Replace with a configuration flag",
          detail:
            "If this is meant to toggle behavior, use `Application.compile_env/3` or a function parameter.",
          applies_when: "This is an intentional feature toggle that was hardcoded."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.42"],
      context: %{construct: :if, value: value},
      file: file,
      line: line
    )
  end

  defp build_cond_diagnostic(file, line) do
    Diagnostic.info("6.42",
      title: "Constant expression",
      message: "cond has `true ->` as the first clause — all subsequent clauses are dead code",
      why:
        "When `true ->` is the first clause in a cond expression, it matches immediately " <>
          "and no other clauses execute. This makes the entire cond pointless. " <>
          "Note: `true ->` as the LAST clause is idiomatic Elixir (default/else branch).",
      alternatives: [
        Fix.new(
          summary: "Remove the cond and keep only the body",
          detail:
            "Since the first clause always matches, replace the entire cond with just that clause's body.",
          applies_when: "The cond is entirely dead code."
        ),
        Fix.new(
          summary: "Reorder clauses",
          detail: "Move `true ->` to the last position as a default handler.",
          applies_when: "The true clause was meant to be the fallback, not the first match."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.42"],
      context: %{construct: :cond},
      file: file,
      line: line
    )
  end

  defp if_branch_desc(true), do: "always taken"
  defp if_branch_desc(false), do: "never taken"
end
