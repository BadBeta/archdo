defmodule Archdo.Rules.CE.MixedModuleSplit do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-4. Modules classified `:mixed` by
  # `Archdo.Volatility` — between :stable and :volatile in dependency
  # density. Mixed modules sit between the two regimes and get
  # neither benefit: they're hard to test (have I/O, can't be
  # pure-tested) so the pure parts pay a Substitutability cost they
  # wouldn't need on their own; they're hard to substitute cleanly
  # (have domain logic) so the volatile parts can't get a clean test
  # seam. Every change to the I/O parts forces re-testing the domain
  # parts and vice versa.

  alias Archdo.{AST, Diagnostic, Fix, Volatility}

  @impl true
  def id, do: "CE-4"

  @impl true
  def description, do: "Mixed-volatility module — split candidate (I/O seam)"

  @impl true
  def analyze(file, ast, opts) do
    case Volatility.classification_for(file, ast, opts) do
      %{tag: :mixed} = c -> [build_diagnostic(file, ast, c)]
      _ -> []
    end
  end

  defp build_diagnostic(file, ast, classification) do
    module = AST.extract_module_name(ast)

    Diagnostic.warning("CE-4",
      title: "Mixed-volatility module — split candidate",
      message:
        "#{module} is mixed (volatile call density #{Float.round(classification.density, 3)}) — " <>
          "split along the I/O seam: pure logic to a stable sibling module, I/O to a " <>
          "thin volatile wrapper",
      why:
        "Mixed modules sit between the :stable and :volatile regimes and get " <>
          "neither benefit. The pure parts pay a Substitutability cost they " <>
          "wouldn't need on their own; the volatile parts can't get a clean test " <>
          "seam. Every change to the I/O parts forces re-testing the domain parts " <>
          "and vice versa — neither Changeability nor Substitutability is preserved.",
      alternatives: [
        Fix.new(
          summary: "Split along the I/O seam",
          detail:
            "Extract pure logic to `#{module}.Pure` (or a sibling module). The " <>
              "I/O retains the original module name (or vice versa) and calls into " <>
              "the pure module. The canonical refactor that converts a mixed " <>
              "module into one stable + one volatile.",
          applies_when:
            "The module's pure logic and I/O are independently meaningful."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-4"],
      context: %{
        module: module,
        volatility_density: classification.density,
        volatile_call_count: length(classification.evidence.volatile_calls)
      },
      file: file,
      line: 1
    )
  end
end
