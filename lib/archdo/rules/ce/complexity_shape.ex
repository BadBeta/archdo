defmodule Archdo.Rules.CE.ComplexityShape do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-24. Quadrant rule on
  # `{cyclomatic_band, cognitive_band}`. The disagreement carries
  # information neither metric provides alone:
  #
  #                  cogn:low       cogn:high
  #   cyclo:high    flat-dispatch  uniform-complex (CE-23 territory)
  #   cyclo:low     simple         twisty-nested
  #
  # Twisty-nested is the genuine refactor target that pure cyclomatic
  # linting misses. Flat-dispatch is over-counted by cyclomatic; we
  # surface it as informational so reviewers can suppress
  # complementary 6.2 noise on idiomatic dispatch.

  alias Archdo.{AST, CognitiveComplexity, Diagnostic, Fix}
  alias Archdo.Rules.Module.FunctionComplexity

  @cyclo_high 8
  @cogn_high 10
  @ratio_threshold 2

  @impl true
  def id, do: "CE-24"

  @impl true
  def description, do: "Cyclomatic / cognitive complexity shape mismatch"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_shape_mismatches(file, ast)
    end
  end

  defp find_shape_mismatches(file, ast) do
    ast
    |> AST.extract_functions(:public)
    |> Enum.flat_map(fn {name, arity, meta, _args, body} ->
      cyclo = FunctionComplexity.compute_complexity(body)
      cogn = CognitiveComplexity.score(body)

      case classify(cyclo, cogn) do
        :twisty_nested ->
          [build_twisty(file, name, arity, meta, cyclo, cogn)]

        :flat_dispatch ->
          [build_flat(file, name, arity, meta, cyclo, cogn)]

        _ ->
          []
      end
    end)
  end

  # Classify the {cyclo, cogn} pair into one of four shapes.
  defp classify(cyclo, cogn) do
    cond do
      twisty_nested?(cyclo, cogn) -> :twisty_nested
      flat_dispatch?(cyclo, cogn) -> :flat_dispatch
      true -> :other
    end
  end

  defp twisty_nested?(cyclo, cogn) do
    cogn >= @cogn_high and cogn > cyclo * @ratio_threshold
  end

  defp flat_dispatch?(cyclo, cogn) do
    cyclo >= @cyclo_high and cyclo > cogn * @ratio_threshold
  end

  # --- diagnostics ---

  defp build_twisty(file, name, arity, meta, cyclo, cogn) do
    Diagnostic.warning("CE-24-twisty",
      title: "Twisty-nested complexity (cognitive >> cyclomatic)",
      message:
        "#{name}/#{arity} has cyclomatic #{cyclo} but cognitive #{cogn} — " <>
          "looks innocent by decision count but is hard to read because of " <>
          "nesting depth or broken control flow",
      why:
        "Cognitive complexity ≥ #{@ratio_threshold}× cyclomatic at threshold " <>
          "#{@cogn_high}+ identifies the genuine refactor target that pure " <>
          "cyclomatic linting misses. The function looks innocent by McCabe " <>
          "metric but the reading-difficulty cost is high.",
      alternatives: [
        Fix.new(
          summary: "Extract sub-functions to flatten nesting",
          detail: "Each level of nesting adds a cognitive penalty proportional to depth.",
          applies_when: "The nested branches have meaningful names."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-24"],
      context: %{cyclomatic: cyclo, cognitive: cogn, shape: :twisty_nested},
      file: file,
      line: AST.line(meta)
    )
  end

  defp build_flat(file, name, arity, meta, cyclo, cogn) do
    Diagnostic.info("CE-24-flat-dispatch",
      title: "Flat-dispatch complexity (cyclomatic >> cognitive)",
      message:
        "#{name}/#{arity} has cyclomatic #{cyclo} but cognitive #{cogn} — " <>
          "many decision points but flat dispatch (large case / multi-clause). " <>
          "Cyclomatic is over-counting; the dispatch is fine.",
      why:
        "Cyclomatic ≥ #{@ratio_threshold}× cognitive at threshold #{@cyclo_high}+ " <>
          "identifies idiomatic Elixir dispatch the McCabe metric over-counts. " <>
          "The function reads cleanly despite the high cyclomatic number — " <>
          "consider suppressing complementary 6.2 (FunctionComplexity) noise " <>
          "at this site.",
      alternatives: [
        Fix.new(
          summary:
            "Suppress 6.2 here with `# archdo:allow 6.2 reason: idiomatic dispatch — see CE-24`",
          detail:
            "Cyclomatic complexity rules over-count flat dispatch. CE-24-flat " <>
              "marks the site as known-fine; suppress 6.2 there to reduce noise.",
          applies_when: "The high cyclomatic is from idiomatic dispatch, not nesting."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-24"],
      context: %{cyclomatic: cyclo, cognitive: cogn, shape: :flat_dispatch},
      file: file,
      line: AST.line(meta)
    )
  end
end
