defmodule Archdo.Severity do
  @moduledoc false

  # §§ elixir-planning: §6 — context-aware severity adjustment.
  # Centralizes the policy "a finding's severity depends on WHERE it was
  # found, not just what the rule says." Plausible self-audit (per
  # elixir-reviewing) revealed that warning-level findings in test files
  # and ad-hoc scripts buried real domain-layer findings; downgrading
  # those non-domain findings to :info restores signal-to-noise.

  alias Archdo.{Diagnostic, Phoenix}

  @type severity :: Diagnostic.severity()

  # M9 audit on Plausible identified rules where the base severity is
  # systematically over-warned regardless of context. These get a hard
  # cap at `:info` — style/subjective/long-term-metric findings that
  # don't merit blocking review.
  #
  # Promotion is not allowed via this table; only downgrades. To
  # escalate a rule, change its base severity in the rule module.
  @rule_max_severity %{
    # 4.5 ImportBreadth — broad imports are a readability choice, not a
    # correctness issue. Plausible self-audit: 34 findings, all style.
    "4.5" => :info,
    # 6.4 ModuleLength — purely subjective threshold; depends on module
    # type (boundary modules legitimately accumulate clauses).
    "6.4" => :info,
    # 6.3 StructFieldCount — same reasoning as 6.4; structs that mirror
    # external API payloads are legitimately wide.
    "6.3" => :info,
    # 6.8 ZoneOfPain — Martin metric. Long-term architectural concern,
    # not a per-PR review item.
    "6.8" => :info
  }

  @doc """
  Adjust a base severity for the layer the finding lives in.

  Policy:

  - `:error` is preserved everywhere — real bugs are real.
  - `:warning` is downgraded to `:info` in non-production layers
    (`:test`, `:other`, `:operational`, `:application_root`). Operational
    layers are typically already filtered upstream by per-rule
    `Phoenix.operational?/1` checks; this is the post-hoc safety net.
  - `:warning` is preserved in production layers (`:context`, `:web`,
    `:live_view`, `:component`, `:controller`, `:router`, `:schema`,
    `:migration`).
  - `:info` is never escalated — already the lowest tier.
  - A nil/missing classification is treated as production.

  The `rule_id` is currently unused but is part of the API so future
  per-rule overrides (e.g. `5.30 ProcessSleep` always `:info` in any
  layer) can be added without changing call sites.
  """
  @spec adjust(String.t(), severity(), Phoenix.classification() | %{layer: atom()} | nil) ::
          severity()
  def adjust(_rule_id, :error, _classification), do: :error
  def adjust(_rule_id, :info, _classification), do: :info

  def adjust(rule_id, :warning, classification) do
    case Map.get(@rule_max_severity, rule_id) do
      :info ->
        :info

      _ ->
        case layer_of(classification) do
          l when l in [:test, :other, :operational, :application_root] -> :info
          _ -> :warning
        end
    end
  end

  @doc """
  Apply `adjust/3` to a `Diagnostic` struct, returning a new struct with
  the adjusted severity.
  """
  @spec adjust_diagnostic(Diagnostic.t(), Phoenix.classification() | %{layer: atom()} | nil) ::
          Diagnostic.t()
  def adjust_diagnostic(%Diagnostic{} = diag, classification) do
    %Diagnostic{diag | severity: adjust(diag.rule_id, diag.severity, classification)}
  end

  defp layer_of(nil), do: :unknown
  defp layer_of(%{layer: layer}), do: layer
  defp layer_of(_), do: :unknown
end
