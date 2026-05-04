defmodule Archdo.Rules.CE.VolatilitySubstitutability do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — first quadrant rule (M21). The proposal's
  # CE-2 (volatile boundary lacks abstraction) and CE-3 (stable core
  # with abstraction overhead) ship as ONE analysis with a 2x2 policy:
  #
  #   abstraction_density × volatility_tag
  #
  #         | volatile | stable    | mixed
  #   high  | earned   | CE-3 fire | (CE-4)
  #   low   | CE-2 fire| correct   | (CE-4)
  #
  # The actionable cells are {:low, :volatile} (missing seam at the
  # boundary) and {:high, :stable} (paying for Substitutability the
  # stable core doesn't need). The other cells produce no finding —
  # cleaner than two separate threshold rules with overlapping logic.
  #
  # Project-level because abstraction-density classification needs the
  # codebase median for thresholding.

  alias Archdo.{AST, Diagnostic, Fix, Volatility}

  @impl true
  def id, do: "CE-2/CE-3"

  @impl true
  def description,
    do: "Volatility/Substitutability matching — fires CE-2 or CE-3 per quadrant cell"

  # Policy table: cell → action. The abstraction axis is three-valued
  # because CE-2 and CE-3 fire on different conditions:
  #
  #   :none   — zero abstractions (CE-2's volatile-boundary trigger)
  #   :high   — abstractions present and density > 2× codebase median
  #             (CE-3's stable-core trigger)
  #   :normal — has some abstractions but not above the median threshold
  #
  # The full 3 × 3 cell space (abstraction × {volatile, stable, mixed}):
  #
  #            volatile        stable        mixed
  #   :none    CE-2 fire       correct       (CE-4)
  #   :normal  earned          correct       (CE-4)
  #   :high    earned          CE-3 fire     (CE-4)
  @policy %{
    {:none, :volatile} => {:fire, :warning, "CE-2", "Volatile boundary lacks abstraction layer"},
    {:high, :stable} =>
      {:fire, :warning, "CE-3", "Stable core with abstraction density above codebase median"}
  }

  @doc "The 2x2 policy table — exposed for metrics + documentation."
  def policy, do: @policy

  @doc """
  Project-level analysis. Computes the codebase median abstraction
  density once, then evaluates each module's cell against the policy
  and emits one Diagnostic per actionable cell.
  """
  @spec analyze_project([{String.t(), Macro.t()}]) :: [Diagnostic.t()]
  def analyze_project(file_asts) do
    production = Enum.reject(file_asts, fn {file, _} -> AST.test_file?(file) end)
    median = codebase_median(production)

    for {file, ast} <- production,
        not AST.behaviour_or_protocol?(ast),
        cell = cell_for(file, ast, median),
        action = Map.get(@policy, cell, :no_finding),
        action != :no_finding do
      build_diagnostic(file, ast, cell, action, median)
    end
  end


  @doc """
  Compute the abstraction density for a single module:
  `(behaviours + callbacks + protocols) / max(public_function_count, 1)`.

  Using `max(..., 1)` keeps the density meaningful for behaviour-only
  modules (interface-style with no public functions) — they still
  surface as high-abstraction.
  """
  @spec abstraction_density(Macro.t()) :: float()
  def abstraction_density(ast) do
    publics = ast |> AST.extract_functions(:public) |> length()
    abstractions = count_abstractions(ast)

    case {abstractions, publics} do
      {0, _} -> 0.0
      {n, 0} -> n * 1.0
      {n, p} -> n / p
    end
  end

  @doc "True when the module has zero abstraction declarations."
  @spec no_abstractions?(Macro.t()) :: boolean()
  def no_abstractions?(ast), do: count_abstractions(ast) == 0

  @doc """
  Compute the median abstraction density across the production module
  set. Used by `analyze_project/1` to set the per-module
  high/low classification threshold.
  """
  @spec codebase_median([{String.t(), Macro.t()}]) :: float()
  def codebase_median(file_asts) do
    densities =
      file_asts
      |> Enum.map(fn {_file, ast} -> abstraction_density(ast) end)
      |> Enum.sort()

    case densities do
      [] -> 0.0
      list -> median(list)
    end
  end

  defp count_abstractions(ast) do
    length(
      AST.find_all(ast, fn
        {:@, _, [{:behaviour, _, _}]} -> true
        {:@, _, [{:callback, _, _}]} -> true
        {:defprotocol, _, _} -> true
        _ -> false
      end)
    )
  end

  defp median(list) do
    n = length(list)
    sorted = list

    case rem(n, 2) do
      0 -> (Enum.at(sorted, div(n, 2) - 1) + Enum.at(sorted, div(n, 2))) / 2
      1 -> Enum.at(sorted, div(n, 2))
    end
  end

  # --- per-module cell ---

  defp cell_for(file, ast, median) do
    abstraction_class = abstraction_class(ast, median)
    volatility_tag = Volatility.classify_module(file, ast).tag
    {abstraction_class, volatility_tag}
  end

  defp abstraction_class(ast, median) do
    density = abstraction_density(ast)
    threshold = max(median * 2, 0.5)

    cond do
      no_abstractions?(ast) -> :none
      density >= threshold -> :high
      true -> :normal
    end
  end

  # --- diagnostic ---

  defp build_diagnostic(file, ast, cell, {:fire, severity, rule_id, title}, median) do
    module = AST.extract_module_name(ast)
    density = abstraction_density(ast)
    {abstraction_class, volatility_tag} = cell

    base_opts = [
      title: title,
      message:
        "#{module}: #{abstraction_class}-abstraction × #{volatility_tag} — #{title} " <>
          "(density #{Float.round(density, 3)}, codebase median #{Float.round(median, 3)})",
      why: why_for(rule_id),
      alternatives: fixes_for(rule_id),
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md##{rule_id}"],
      context: %{
        cell: cell,
        density: density,
        median: median,
        module: module
      },
      file: file,
      line: 1
    ]

    builder = Diagnostic.builder_for(severity)
    builder.(rule_id, base_opts)
  end

  defp why_for("CE-2") do
    "When a volatile module is exposed to multiple non-volatile callers without " <>
      "any abstraction (behaviour / protocol / configurable adapter), every " <>
      "caller is affected by external changes (API version, vendor swap). The " <>
      "Substitutability layer is the insulation that absorbs external change " <>
      "without ripple — and it's missing exactly where the volatility presumption " <>
      "says it earns its keep."
  end

  defp why_for("CE-3") do
    "Substitutability is being paid for in the part of the system that doesn't " <>
      "need it. Pure stable code already has full Changeability through " <>
      "simplicity alone — adding behaviours / protocols / configurable adapters " <>
      "here gives nothing extra and adds concepts the reader must navigate. " <>
      "This is the inverse of CE-2."
  end

  defp fixes_for("CE-2") do
    [
      Fix.new(
        summary: "Introduce a behaviour at the boundary",
        detail:
          "Define a `MyApp.X.Adapter` behaviour, route callers through it, and " <>
            "register the current implementation as the default. Mox-mocked in " <>
            "tests; swap providers without touching call sites.",
        applies_when: "The module wraps a vendor / external dependency."
      )
    ]
  end

  defp fixes_for("CE-3") do
    [
      Fix.new(
        summary: "Inline the abstractions and rely on simplicity",
        detail:
          "Stable code's Changeability comes from clear naming, low coupling, " <>
            "good tests — not from abstraction layers. Remove behaviours / " <>
            "protocols that aren't backed by multiple real implementations.",
        applies_when: "The abstractions don't have multiple producers / consumers."
      )
    ]
  end
end
