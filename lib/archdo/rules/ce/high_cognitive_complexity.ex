defmodule Archdo.Rules.CE.HighCognitiveComplexity do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-23. Public function whose cognitive
  # complexity (Campbell, SonarSource 2018) exceeds the threshold.
  # Cognitive tracks reading difficulty, not graph paths — flat
  # dispatch (large `case`, multi-clause functions) is NOT penalized;
  # nesting depth is. The function is hard to read, hard to modify
  # safely, and hard to test exhaustively.

  alias Archdo.{AST, CognitiveComplexity, Diagnostic, Fix}

  @warning_threshold 15
  @error_threshold 25

  @impl true
  def id, do: "CE-23"

  @impl true
  def description, do: "Public function with high cognitive complexity (Campbell)"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_high_cognitive(file, ast)
    end
  end

  defp find_high_cognitive(file, ast) do
    ast
    |> AST.extract_functions(:public)
    |> Enum.flat_map(fn {name, arity, meta, _args, body} ->
      case body && CognitiveComplexity.score(body) do
        nil ->
          []

        score when score >= @error_threshold ->
          [build_diagnostic(file, name, arity, meta, score, :error)]

        score when score >= @warning_threshold ->
          [build_diagnostic(file, name, arity, meta, score, :warning)]

        _ ->
          []
      end
    end)
  end

  defp build_diagnostic(file, name, arity, meta, score, severity) do
    builder = Diagnostic.builder_for(severity)

    builder.("CE-23",
      title: "High cognitive complexity",
      message:
        "#{name}/#{arity} has cognitive complexity #{score} (threshold #{@warning_threshold}, " <>
          "error at #{@error_threshold}) — hard to read, hard to modify safely, hard to test",
      why:
        "Cognitive complexity (Campbell) measures reading difficulty: nesting + " <>
          "broken control flow penalize linearly with depth. Unlike cyclomatic, " <>
          "flat dispatch is NOT penalized — so this finding is specifically about " <>
          "tangled control flow, not large case statements. Every change risks " <>
          "one of the implicit branches; tests can't cover the full state space.",
      alternatives: [
        Fix.new(
          summary: "Extract sub-functions to flatten nesting",
          detail:
            "Pull each branch's body into a named helper. Even if the branch is " <>
              "small, naming it documents intent and removes a level of nesting.",
          applies_when: "The branches have meaningful names you can give them."
        ),
        Fix.new(
          summary: "Convert nested case/if to multi-clause function dispatch",
          detail:
            "Multi-clause functions are flat dispatch; cognitive doesn't penalize " <>
              "them. `case x do :a -> handle_a(); :b -> handle_b() end` becomes " <>
              "`def handle(:a), do: ...; def handle(:b), do: ...`.",
          applies_when:
            "The branches dispatch on a single value's shape and don't share local state."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-23"],
      context: %{cognitive_score: score, threshold: @warning_threshold},
      file: file,
      line: AST.line(meta)
    )
  end
end
