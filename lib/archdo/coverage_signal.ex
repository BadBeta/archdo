defmodule Archdo.CoverageSignal do
  @moduledoc """
  Post-run pass that flags rules firing on a large fraction of analyzed
  units (typically files / modules). When a single rule fires on >30% of
  units, the most likely explanation is that the rule's model doesn't
  fit this project's shape — not that 30%+ of the code is broken.

  Returned diagnostics for matching rules get `:confidence` downgraded to
  `:medium`, and a footer note is emitted so reviewers see the signpost
  rather than triaging hundreds of findings.

  The pass is generic — no per-rule allowlist. Any rule whose coverage
  rate crosses the threshold is downgraded, including rules added later.
  """

  alias Archdo.Diagnostic

  @default_threshold 0.30

  @type note :: %{
          rule_id: String.t(),
          units_affected: pos_integer(),
          total_units: pos_integer(),
          coverage_rate: float()
        }

  @doc """
  Apply the coverage-rate downgrade to `diagnostics` over `total_units`
  analyzed files. Returns `{annotated_diagnostics, notes}`.

  Options:
    * `:threshold` — float in `0.0..1.0`, default `#{@default_threshold}`.
      Rules whose `(distinct_files_affected / total_units)` strictly
      exceeds this threshold are downgraded.
  """
  @spec annotate([Diagnostic.t()], non_neg_integer(), keyword()) ::
          {[Diagnostic.t()], [note()]}
  def annotate(diagnostics, total_units, opts \\ [])

  # §§ elixir-implementing: §2.1 — multi-clause dispatch on shape (empty
  # list / zero units) rather than `if` in the body. Both early-return
  # cases collapse to the identity transform with no notes.
  def annotate([], _total_units, _opts), do: {[], []}
  def annotate(diagnostics, 0, _opts), do: {diagnostics, []}

  def annotate(diagnostics, total_units, opts)
      when is_list(diagnostics) and is_integer(total_units) and total_units > 0 do
    threshold = Keyword.get(opts, :threshold, @default_threshold)

    rule_coverage = compute_rule_coverage(diagnostics, total_units)
    flagged = flagged_rule_ids(rule_coverage, threshold)

    annotated =
      case flagged do
        empty when map_size(empty) == 0 -> diagnostics
        _ -> Enum.map(diagnostics, &maybe_downgrade(&1, flagged))
      end

    notes =
      flagged
      |> Map.values()
      |> Enum.sort_by(&(-&1.coverage_rate))

    {annotated, notes}
  end

  defp compute_rule_coverage(diagnostics, total_units) do
    diagnostics
    |> Enum.group_by(& &1.rule_id, & &1.file)
    |> Map.new(fn {rule_id, files} ->
      distinct = files |> Enum.uniq() |> length()

      {rule_id,
       %{units_affected: distinct, total_units: total_units, rate: distinct / total_units}}
    end)
  end

  defp flagged_rule_ids(rule_coverage, threshold) do
    rule_coverage
    |> Enum.filter(fn {_rule_id, %{rate: rate}} -> rate > threshold end)
    |> Map.new(fn {rule_id, %{units_affected: u, total_units: t, rate: r}} ->
      {rule_id, %{rule_id: rule_id, units_affected: u, total_units: t, coverage_rate: r}}
    end)
  end

  # §§ M-fb-F1 — only downgrade :high; never upgrade :low or :medium. A
  # rule that emits :low confidence intentionally (e.g. a heuristic-based
  # rule) shouldn't be silently "promoted" because it coincidentally
  # crosses the coverage threshold.
  defp maybe_downgrade(%Diagnostic{rule_id: rule_id, confidence: :high} = d, flagged)
       when is_map_key(flagged, rule_id),
       do: Diagnostic.with_confidence(d, :medium)

  defp maybe_downgrade(diagnostic, _flagged), do: diagnostic
end
