defmodule Archdo.DocCoverage do
  @moduledoc """
  Compares the rule registry against `ARCHITECTURE_RULES.md` so the
  reference document stays in sync with the rules that actually exist.

  Two queries:

    * `audit/2` — given the registry IDs and the doc IDs, returns
      `:ok` (no gap) or `{:gap, %{missing: [...], stale: [...]}}`.
    * `audit_against_baseline/3` — same comparison but tolerates the
      pre-existing missing IDs listed in a baseline file. Used by
      the doc-coverage test as a regression guard: a NEW rule added
      without docs fails the test, but the work-in-progress backlog
      doesn't break CI.

  The Mix task `mix archdo.audit_doc_coverage` and the test
  `test/doc_coverage_test.exs` consume this module.

  Doc IDs are extracted by matching `### N.M Title` (or `### CE-XX
  Title`, etc.) headings in the markdown source. The registry IDs
  come from `Archdo.Rules.phase1_rules/0`, `graph_rules/0`,
  `project_rules/0`, and `compiled_rules/0` (when available).
  """

  @doc """
  Lists every unique rule id from the rule registries.
  """
  @spec registered_rule_ids() :: [String.t()]
  def registered_rule_ids do
    phase1 = safe_call(Archdo.Rules, :phase1_rules, [])
    graph = safe_call(Archdo.Rules, :graph_rules, [])
    project = safe_call(Archdo.Rules, :project_rules, [])
    compiled = safe_call(Archdo.Rules, :compiled_rules, [])

    (phase1 ++ graph ++ project ++ compiled)
    |> Enum.uniq()
    |> Enum.map(& &1.id())
    |> Enum.uniq()
  end

  @doc """
  Extracts rule ids from `### X.Y Title` headings in markdown.
  """
  @spec documented_rule_ids(String.t()) :: [String.t()]
  def documented_rule_ids(markdown) when is_binary(markdown) do
    markdown
    |> String.split("\n")
    |> Enum.flat_map(&extract_id/1)
    |> Enum.uniq()
  end

  # Rule-id shapes that count as documented entries. Anything else
  # in a `### ` heading is a subsection / category divider that
  # the gap analysis should ignore.
  #
  #   1.1, 5.50, 6.103   — numbered rules
  #   1.1b               — variant suffix
  #   CE-1, CE-50        — change economy
  #   SM-A, SM-D         — state-machine letter ids
  @id_pattern ~r/^###\s+(?<id>(?:\d+\.\d+[a-z]?|CE-\d+|SM-[A-Z]))(?:\s|$)/

  defp extract_id(line) do
    case Regex.named_captures(@id_pattern, line) do
      %{"id" => id} -> [id]
      nil -> []
    end
  end

  @doc """
  Compares registry against doc. Returns `:ok` if they match,
  `{:gap, %{missing: ..., stale: ...}}` otherwise. Lists are sorted
  lexicographically for stable output.
  """
  @spec audit([String.t()], [String.t()]) ::
          {:ok, %{missing: [], stale: []}} | {:gap, %{missing: [String.t()], stale: [String.t()]}}
  def audit(registry, doc) when is_list(registry) and is_list(doc) do
    registry_set = MapSet.new(registry)
    doc_set = MapSet.new(doc)

    missing = registry_set |> MapSet.difference(doc_set) |> MapSet.to_list() |> Enum.sort()
    stale = doc_set |> MapSet.difference(registry_set) |> MapSet.to_list() |> Enum.sort()

    case {missing, stale} do
      {[], []} -> {:ok, %{missing: [], stale: []}}
      _ -> {:gap, %{missing: missing, stale: stale}}
    end
  end

  @doc """
  Regression-guard form (3-arity, missing baseline only). Tolerates
  the acknowledged-missing IDs but reports any stale entries as
  errors. Returns:

    * `:ok` — no new undocumented rules and no stale doc entries
    * `{:error, %{new_undocumented: [...]}}` — a rule is missing
      from the doc and not in the baseline
    * `{:error, %{stale: [...]}}` — the doc references a rule that
      no longer exists in the registry
    * `{:error, %{new_undocumented: [...], stale: [...]}}` — both
  """
  @spec audit_against_baseline([String.t()], [String.t()], [String.t()]) ::
          :ok | {:error, map()}
  def audit_against_baseline(registry, doc, baseline)
      when is_list(registry) and is_list(doc) and is_list(baseline) do
    case audit(registry, doc) do
      {:ok, _} ->
        :ok

      {:gap, %{missing: missing, stale: stale}} ->
        new_undocumented = subset_diff(missing, baseline)

        case {new_undocumented, stale} do
          {[], []} -> :ok
          {[], stale} -> {:error, %{stale: stale}}
          {n_u, []} -> {:error, %{new_undocumented: n_u}}
          {n_u, stale} -> {:error, %{new_undocumented: n_u, stale: stale}}
        end
    end
  end

  @doc """
  Regression-guard form (4-arity, missing + stale baselines). Both
  missing and stale lists are tolerated as long as the current set
  is a subset of the corresponding baseline. Use this during the
  doc-completion milestone work where the stale-entries cleanup is
  on a separate milestone from the missing-rule work.

  Reports `:new_undocumented` and `:new_stale` separately so the
  failure message names which baseline grew.
  """
  @spec audit_against_baseline([String.t()], [String.t()], [String.t()], [String.t()]) ::
          :ok | {:error, map()}
  def audit_against_baseline(registry, doc, missing_baseline, stale_baseline)
      when is_list(registry) and is_list(doc) and is_list(missing_baseline) and
             is_list(stale_baseline) do
    case audit(registry, doc) do
      {:ok, _} ->
        :ok

      {:gap, %{missing: missing, stale: stale}} ->
        new_undocumented = subset_diff(missing, missing_baseline)
        new_stale = subset_diff(stale, stale_baseline)

        case {new_undocumented, new_stale} do
          {[], []} -> :ok
          {[], new_stale} -> {:error, %{new_stale: new_stale}}
          {new_undocumented, []} -> {:error, %{new_undocumented: new_undocumented}}
          {n_u, n_s} -> {:error, %{new_undocumented: n_u, new_stale: n_s}}
        end
    end
  end

  defp subset_diff(actual, baseline) do
    baseline_set = MapSet.new(baseline)
    Enum.reject(actual, &MapSet.member?(baseline_set, &1))
  end

  defp safe_call(mod, fun, default) do
    _ = Code.ensure_loaded(mod)

    case function_exported?(mod, fun, 0) do
      true -> apply(mod, fun, [])
      false -> default
    end
  end
end
