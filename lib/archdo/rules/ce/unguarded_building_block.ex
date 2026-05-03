defmodule Archdo.Rules.CE.UnguardedBuildingBlock do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-57 (M-Aux6). A function whose Blackbox
  # score is ≥ 0.9 on the existing six components but whose head does
  # not constrain its input domain. Such a function looks like a
  # building block structurally — pure, deterministic, side-effect-
  # free — but a caller passing out-of-domain input crashes deep in
  # the body (`** (ArithmeticError)`, `** (BadMapError)`) instead of
  # receiving a controlled domain error.
  #
  # Per the user's intent: "illegal inputs should be an expected
  # error." This rule surfaces candidates that don't enforce that.
  #
  # A clause is "constrained" when AT LEAST ONE of:
  #   - the head has a `when` guard
  #   - all argument patterns are specific (no bare-variable args)
  #   - the body's last expression is an `{:error, _}` literal
  #     (clause is the explicit error fallback)
  #
  # The function is "well-guarded" when EVERY clause is constrained.
  # The rule fires when ANY clause is unconstrained.
  #
  # Pack: `:ce_composability` — joins CE-54/55/56 covering different
  # facets of building-block readiness.

  alias Archdo.{AST, Blackbox, Diagnostic, Fix, InputGuard}

  @candidate_threshold 0.9

  @impl true
  def id, do: "CE-57"

  @impl true
  def description,
    do:
      "Building-block candidate accepts unguarded input — illegal inputs crash instead of returning {:error, _}"

  @impl true
  def pack, do: :ce_composability

  @impl true
  def analyze(file, ast, _opts) do
    cond do
      AST.test_file?(file) -> []
      AST.has_marker?(ast, :archdo_no_input_check) -> []
      true -> find_unguarded_candidates(file, ast)
    end
  end

  defp find_unguarded_candidates(file, ast) do
    scores = Blackbox.score_module(ast)
    clauses_by_key = InputGuard.collect_clauses(ast)

    scores
    |> Enum.filter(fn {_n, arity, score, _c} ->
      score >= @candidate_threshold and arity > 0
    end)
    |> Enum.flat_map(fn {name, arity, _score, _components} ->
      key = {name, arity}
      clauses = Map.get(clauses_by_key, key, [])

      case InputGuard.any_unconstrained?(clauses) do
        true -> [build_diagnostic(file, name, arity, hd(clauses).meta)]
        false -> []
      end
    end)
  end

  defp build_diagnostic(file, name, arity, meta) do
    Diagnostic.info("CE-57",
      title: "Building-block candidate accepts unguarded input",
      message:
        "#{name}/#{arity}: scores ≥ #{@candidate_threshold} on the six core Blackbox " <>
          "components but at least one clause has bare-variable args without a " <>
          "guard or `{:error, _}` fallback — illegal inputs crash deep in the body " <>
          "instead of returning a controlled domain error.",
      why:
        "A function that's pure, deterministic, side-effect-free, and " <>
          "spec-covered LOOKS like a building block. But if its head accepts any " <>
          "input (`def f(x), do: x * 2`), a caller passing the wrong type " <>
          "(`f(\"foo\")`) crashes deep with `ArithmeticError` or `BadMapError`. " <>
          "True building blocks make the input domain explicit at the boundary: " <>
          "guards in the head OR specific patterns OR an `{:error, _}` fallback. " <>
          "Illegal input becomes an EXPECTED error, not an opaque crash.",
      alternatives: [
        Fix.new(
          summary: "Add a guard to the function head",
          detail:
            "`def #{name}(x) when is_integer(x), do: ...` — out-of-domain calls " <>
              "fail at the boundary with a clear FunctionClauseError naming this " <>
              "function, not deep in the body with a type error.",
          applies_when: "The legal input domain is expressible as a guard predicate."
        ),
        Fix.new(
          summary: "Add a fallback clause returning {:error, :invalid_input}",
          detail:
            "Keep the working clauses, then add `def #{name}(_), do: {:error, " <>
              ":invalid_input}` as the catch-all. Out-of-domain callers get a " <>
              "tagged-tuple error they can compose into `with` chains. Note: the " <>
              "function's return type widens to `result | {:error, _}`.",
          applies_when:
            "The function is part of a public API where callers prefer error tuples to exceptions."
        ),
        Fix.new(
          summary: "Mark @archdo_no_input_check if the call site pre-validates",
          detail:
            "If every caller pre-validates input via the context boundary (e.g., " <>
              "an Ecto changeset has already enforced types), declare it: " <>
              "`@archdo_no_input_check \"all callers pre-validate via context\"` " <>
              "at module level.",
          applies_when:
            "The function is internal-only and the caller's contract enforces the domain."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-57"],
      context: %{function: "#{name}/#{arity}"},
      file: file,
      line: AST.line(meta)
    )
  end
end
