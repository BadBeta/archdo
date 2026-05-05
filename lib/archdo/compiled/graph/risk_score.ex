defmodule Archdo.Compiled.Graph.RiskScore do
  @moduledoc """
  Composite per-function risk score derived from PageRank, cyclomatic
  complexity, Halstead effort, and afferent+efferent coupling.

  Each input is expected to be **already normalized to `[0, 1]`** —
  callers compute the raw values via the metric modules
  (`Archdo.Compiled.Graph.Centrality.page_rank/1`, the existing 6.2
  cyclomatic computation, `Archdo.Stats.Halstead.analyze_function/1`,
  the Martin coupling table) and rescale them across the cohort
  before passing to this module.

  The score is a weighted geometric mean: any factor reaching 0
  zeroes the score. This is deliberate — a function that's never
  called (PageRank=0) is never the riskiest one to change, regardless
  of internal complexity. With all factors equal to `x`, the score is
  exactly `x`.
  """

  Module.register_attribute(__MODULE__, :archdo_volatility, persist: true)
  @archdo_volatility :stable

  @type input :: %{
          pagerank: float(),
          complexity: float(),
          halstead: float(),
          coupling: float()
        }

  @type score_map :: %{any() => float()}

  @weights %{
    pagerank: 0.4,
    complexity: 0.25,
    halstead: 0.15,
    coupling: 0.20
  }

  @doc """
  The weight vector. Sum is 1.0 by construction. Public so callers can
  audit or override (planned for future tuning) without reading source.
  """
  @spec weights() :: %{atom() => float()}
  def weights, do: @weights

  @doc """
  Compute the composite risk score from a per-node input map. Each
  value must be a 4-key map with keys `:pagerank`, `:complexity`,
  `:halstead`, `:coupling`, all floats in `[0, 1]`. Returns
  `%{node => score}` with the same keys as the input.
  """
  @spec compute_from(%{any() => input()}) :: score_map()
  def compute_from(inputs) when is_map(inputs) do
    Map.new(inputs, fn {node, vals} -> {node, score(vals)} end)
  end

  defp score(%{pagerank: p, complexity: c, halstead: h, coupling: k}) do
    case any_zero?([p, c, h, k]) do
      true -> 0.0
      false -> geometric_mean(p, c, h, k)
    end
  end

  defp any_zero?(values), do: Enum.any?(values, fn v -> v == 0 or v == 0.0 end)

  # Weighted geometric mean: exp(Σ w_i · ln x_i)
  defp geometric_mean(p, c, h, k) do
    %{pagerank: wp, complexity: wc, halstead: wh, coupling: wk} = @weights
    log_sum = wp * :math.log(p) + wc * :math.log(c) + wh * :math.log(h) + wk * :math.log(k)
    :math.exp(log_sum)
  end
end
