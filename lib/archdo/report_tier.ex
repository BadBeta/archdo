defmodule Archdo.ReportTier do
  @moduledoc """
  Severity-tier filter for `mix archdo` reports.

  Maps a friendly tier name to the set of `Archdo.Diagnostic` severities
  it includes. The CLI's `--report-tier=<tier>` flag passes the tier
  through to `filter/2`.

      mix archdo --report-tier=critical      # errors only
      mix archdo --report-tier=architectural # errors + warnings
      mix archdo --report-tier=quality       # info + nitpicks
      mix archdo --report-tier=all           # default — everything

  ## Why severity-based, not pass-based

  Earlier drafts mapped tiers to cleanup-guide passes. That overlapped
  with `--cleanup-pass=N` and confused the call site. Severity-based
  tiers are orthogonal: combine `--cleanup-pass=6 --report-tier=critical`
  to see only deserialization errors, omit either to widen.
  """

  # `{:error, msg}` returned to caller (Mix task prints to stderr) on bad CLI flag.
  Module.register_attribute(__MODULE__, :archdo_silent_error, persist: true)
  @archdo_silent_error true

  @type tier :: :critical | :architectural | :quality | :all

  @tier_severities %{
    critical: [:error],
    architectural: [:error, :warning],
    quality: [:info, :nitpick],
    all: [:error, :warning, :info, :nitpick]
  }

  @doc "Returns the severity list for a tier."
  @spec severities_for(tier()) :: [Archdo.Diagnostic.severity()]
  def severities_for(tier) when tier in [:critical, :architectural, :quality, :all],
    do: Map.fetch!(@tier_severities, tier)

  @doc """
  Filters diagnostics by tier. `nil` and `:all` pass through unchanged.
  """
  @spec filter([Archdo.Diagnostic.t()], tier() | nil) :: [Archdo.Diagnostic.t()]
  def filter(diagnostics, nil), do: diagnostics
  def filter(diagnostics, :all), do: diagnostics

  def filter(diagnostics, tier) when tier in [:critical, :architectural, :quality] do
    severities = MapSet.new(severities_for(tier))
    Enum.filter(diagnostics, &MapSet.member?(severities, &1.severity))
  end

  @doc "Parse a CLI string into a tier atom."
  @spec parse(String.t()) :: {:ok, tier()} | {:error, String.t()}
  def parse("critical"), do: {:ok, :critical}
  def parse("architectural"), do: {:ok, :architectural}
  def parse("quality"), do: {:ok, :quality}
  def parse("all"), do: {:ok, :all}

  def parse(other),
    do: {:error, "unknown report tier: #{inspect(other)}; expected one of: " <> labels_text()}

  @doc "All valid tier names in canonical order."
  @spec all_tiers() :: [tier()]
  def all_tiers, do: [:critical, :architectural, :quality, :all]

  defp labels_text, do: Enum.map_join(all_tiers(), ", ", &Atom.to_string/1)
end
