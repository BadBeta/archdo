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

  alias Archdo.{AST, Blackbox, Diagnostic, Fix}

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
    clauses_by_key = collect_clauses(ast)

    scores
    |> Enum.filter(fn {_n, arity, score, _c} ->
      score >= @candidate_threshold and arity > 0
    end)
    |> Enum.flat_map(fn {name, arity, _score, _components} ->
      key = {name, arity}
      clauses = Map.get(clauses_by_key, key, [])

      case any_unconstrained?(clauses) do
        true -> [build_diagnostic(file, name, arity, hd(clauses).meta)]
        false -> []
      end
    end)
  end

  # Walk the AST collecting all `def name(...) [when ...] do ... end`
  # clauses. Returns %{{name, arity} => [%{args, guard?, body, meta}, ...]}.
  defp collect_clauses(ast) do
    {_, by_key} =
      Macro.prewalk(ast, %{}, fn
        # Guarded def: {:def, meta, [{:when, _, [{name, _, args}, _guard]}, body]}
        {:def, meta, [{:when, _, [{name, _, args} | _]}, body]} = node, acc
        when is_atom(name) and is_list(args) ->
          clause = %{args: args, guard?: true, body: body, meta: meta}
          {node, Map.update(acc, {name, length(args)}, [clause], &(&1 ++ [clause]))}

        # Plain def: {:def, meta, [{name, _, args}, body]}
        {:def, meta, [{name, _, args}, body]} = node, acc
        when is_atom(name) and is_list(args) ->
          clause = %{args: args, guard?: false, body: body, meta: meta}
          {node, Map.update(acc, {name, length(args)}, [clause], &(&1 ++ [clause]))}

        node, acc ->
          {node, acc}
      end)

    by_key
  end

  defp any_unconstrained?(clauses) do
    Enum.any?(clauses, &unconstrained?/1)
  end

  defp unconstrained?(%{guard?: true}), do: false
  defp unconstrained?(%{args: args, body: body}) do
    not all_specific_args?(args) and not returns_error_tuple?(body)
  end

  # All arguments are specific patterns (atoms, structs, tuples,
  # literal numbers, etc.) — NO bare variables. A single bare variable
  # arg breaks the constraint.
  defp all_specific_args?(args) when is_list(args) do
    Enum.all?(args, &specific_arg?/1)
  end

  defp specific_arg?({:_, _, ctx}) when is_atom(ctx), do: false
  defp specific_arg?({var, _, ctx}) when is_atom(var) and is_atom(ctx), do: false
  defp specific_arg?(_), do: true

  # The clause body's last expression is a literal `{:error, _}` tuple.
  # Handles bare-parser and literal_encoder-wrapped shapes.
  defp returns_error_tuple?(body) do
    case last_expression(body) do
      {{:__block__, _, [:error]}, _} -> true
      {:error, _} -> true
      _ -> false
    end
  end

  defp last_expression(body) when is_list(body) do
    case AST.do_body(body) do
      {:__block__, _, statements} -> List.last(statements)
      single -> single
    end
  end

  defp last_expression({:__block__, _, statements}), do: List.last(statements)
  defp last_expression(single), do: single

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
          applies_when: "The function is internal-only and the caller's contract enforces the domain."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-57"],
      context: %{function: "#{name}/#{arity}"},
      file: file,
      line: AST.line(meta)
    )
  end
end
