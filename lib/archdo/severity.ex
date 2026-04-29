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

  def adjust(_rule_id, :warning, classification) do
    case layer_of(classification) do
      l when l in [:test, :other, :operational, :application_root] -> :info
      _ -> :warning
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
