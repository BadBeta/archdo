defmodule Archdo.Rules.CE.UntestedBuildingBlock do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-55. A function whose Blackbox score is
  # ≥ 0.9 (a building block) without a StreamData property test
  # exercising it. The function already has every property property-
  # based testing requires (purity, determinism, closed input, total
  # output, side-effect freedom, errors-as-values). The cost of adding
  # the property test is low; the coverage gain is large.

  alias Archdo.{AST, Blackbox, Diagnostic, Fix}

  @impl true
  def id, do: "CE-55"

  @impl true
  def description,
    do: "Building-block function (Blackbox ≥0.9) without a StreamData property test"

  @impl true
  def pack, do: :ce_composability

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc "Project-level. One Diagnostic per untested building-block function."
  @spec analyze_project([{String.t(), Macro.t()}], keyword()) :: [Diagnostic.t()]
  def analyze_project(file_asts, _opts \\ []) do
    {prod, tests} =
      Enum.split_with(file_asts, fn {file, _} -> not AST.test_file?(file) end)

    property_calls = collect_property_calls(tests)

    Enum.flat_map(prod, &module_diagnostics(&1, property_calls))
  end

  defp module_diagnostics({file, ast}, property_calls) do
    case AST.has_marker?(ast, :archdo_no_property) do
      true -> []
      false -> find_untested_blocks(file, ast, property_calls)
    end
  end

  defp find_untested_blocks(file, ast, property_calls) do
    module = AST.extract_module_name(ast)
    scores = Blackbox.score_module(ast)

    scores
    |> Enum.filter(fn {_n, _a, score, _c} -> score >= 0.9 end)
    |> Enum.flat_map(fn {name, arity, score, _c} ->
      case MapSet.member?(property_calls, {module, name, arity}) do
        true -> []
        false -> [build_diagnostic(file, module, name, arity, score)]
      end
    end)
  end

  # Returns MapSet of {module_name_string, fn_name_atom, arity} called
  # inside any `property "..." do ... end` block across the test files.
  defp collect_property_calls(test_file_asts) do
    test_file_asts
    |> Enum.flat_map(fn {_file, ast} -> property_block_calls(ast) end)
    |> MapSet.new()
  end

  defp property_block_calls(ast) do
    {_, calls} =
      Macro.prewalk(ast, [], fn
        {:property, _, [_name, kw]} = node, acc when is_list(kw) ->
          body = AST.do_body(kw)
          new_calls = collect_remote_calls(body)
          {node, new_calls ++ acc}

        node, acc ->
          {node, acc}
      end)

    calls
  end

  # All `Mod.fun(args)` calls inside a body, returned as
  # {module_name_string, fn_name, arity}.
  defp collect_remote_calls(nil), do: []

  defp collect_remote_calls(body) do
    {_, calls} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, parts}, fun]}, _, args} = node, acc
        when is_list(parts) and is_atom(fun) and is_list(args) ->
          case Enum.all?(parts, &is_atom/1) do
            true ->
              module = Enum.map_join(parts, ".", &Atom.to_string/1)
              {node, [{module, fun, length(args)} | acc]}

            false ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    calls
  end

  defp build_diagnostic(file, module, name, arity, score) do
    Diagnostic.info("CE-55",
      title: "Building-block function without property test",
      message:
        "#{module}.#{name}/#{arity}: scores #{Float.round(score, 2)} on Blackbox " <>
          "(building block) but no `property` block in test/ exercises it. The " <>
          "natural test for this function is property-based — the components " <>
          "required (purity, determinism, closed input) are all in place.",
      why:
        "A function with score ≥ 0.9 is structurally ready for property testing — " <>
          "every component property tests need (closed input, determinism, total " <>
          "output, no hidden state) is already in place. The cost of adding the " <>
          "property test is small (typically 5–10 lines); the coverage gain over " <>
          "example-based tests is large because StreamData explores edge cases " <>
          "humans miss. Skipping this is leaving compounding value on the table.",
      alternatives: [
        Fix.new(
          summary: "Add a StreamData property using the function's @spec as generator",
          detail:
            "`use ExUnitProperties` + `property \"#{name} ...\" do check all x <- " <>
              "integer() do assert ... end end`. Properties to consider: identity " <>
              "(reverse-of-reverse), closure (output type matches), monotonicity, " <>
              "boundary clamping, distributivity over inputs.",
          applies_when: "The function has invariants you can express."
        ),
        Fix.new(
          summary: "Mark @archdo_no_property if property testing isn't applicable",
          detail:
            "If the function's invariants are genuinely hard to express (rare for " <>
              "true building blocks), declare it: `@archdo_no_property \"reason\"` " <>
              "at module level.",
          applies_when: "The function is a building block but property-resistant."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-55"],
      context: %{module: module, function: "#{name}/#{arity}", blackbox_score: score},
      file: file,
      line: 1
    )
  end
end
