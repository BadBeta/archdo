defmodule Archdo.Freeze do
  @moduledoc false

  # Baseline mechanism for gradual adoption.
  #
  # The problem: when you add Archdo to an existing project with 500
  # violations, you don't want to fix all of them at once. You want to
  # freeze the current state and only flag NEW violations from here on.
  #
  # The solution:
  # 1. `mix archdo --freeze` captures the current violation set
  # 2. `mix archdo` filters baseline violations out by default
  # 3. New violations show up. Fixed violations stay fixed (don't show up
  #    again if re-introduced — the freeze tracks intent, not line counts)
  # 4. `--show-all` bypasses the baseline
  # 5. `--freeze-stats` reports how many baseline items are still present
  #    vs resolved

  alias Archdo.Diagnostic

  @default_path ".archdo_baseline.exs"

  @type fingerprint :: String.t()
  @type baseline :: MapSet.t(fingerprint())

  @doc """
  Compute a stable fingerprint for a diagnostic.

  The fingerprint is deliberately line-number-independent so that reformatting
  or adding unrelated code above the violation doesn't churn the baseline.

  The fingerprint includes:
    * rule_id — the rule that fired
    * file — which file it's in
    * identifier — extracted from the message (module, function, or structural hint)

  If no identifier can be extracted, we fall back to a hash of the full
  message, which is stable unless the message text changes.
  """
  @spec fingerprint(Diagnostic.t()) :: fingerprint()
  def fingerprint(%Diagnostic{} = d) do
    identifier = extract_identifier(d.message) || stable_hash(d.message)
    normalized_file = normalize_file(d.file)

    "#{d.rule_id}|#{normalized_file}|#{identifier}"
  end

  @doc """
  Load a baseline from disk. Returns a MapSet of fingerprints.
  """
  @spec load(Path.t()) :: baseline()
  def load(path \\ @default_path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> MapSet.new()
    else
      MapSet.new()
    end
  end

  @doc """
  Save a baseline to disk. The file is a sorted, human-readable list of
  fingerprints with a header comment. Sorted by fingerprint so that
  regenerating produces stable diffs.
  """
  @spec save([Diagnostic.t()], Path.t()) :: :ok
  def save(diagnostics, path \\ @default_path) do
    fingerprints =
      diagnostics
      |> Enum.map(&fingerprint/1)
      |> Enum.uniq()
      |> Enum.sort()

    header = [
      "# Archdo baseline — captured #{format_timestamp()}\n",
      "# #{length(fingerprints)} fingerprints (#{length(diagnostics)} original diagnostics)\n",
      "#\n",
      "# Each line is: rule_id|file|identifier\n",
      "# Commit this file to track which violations are accepted as existing.\n",
      "# Fingerprints are line-number independent — formatting changes won't churn them.\n",
      "\n"
    ]

    body = Enum.map(fingerprints, &(&1 <> "\n"))

    File.write!(path, header ++ body)
    :ok
  end

  @doc """
  Split diagnostics into {new, baselined}. New diagnostics are those not
  present in the baseline — these are what users should act on.
  Baselined diagnostics are pre-existing violations the user accepted.
  """
  @spec partition([Diagnostic.t()], baseline()) :: {[Diagnostic.t()], [Diagnostic.t()]}
  def partition(diagnostics, baseline) do
    Enum.split_with(diagnostics, fn d -> not MapSet.member?(baseline, fingerprint(d)) end)
  end

  @doc """
  Summarize baseline status:
    * still_present — baselined fingerprints still firing
    * resolved — baselined fingerprints no longer firing (good — you fixed them!)
    * new — new diagnostics not in the baseline
  """
  @spec stats([Diagnostic.t()], baseline()) :: map()
  def stats(diagnostics, baseline) do
    current_fingerprints = MapSet.new(diagnostics, &fingerprint/1)

    still_present = MapSet.intersection(baseline, current_fingerprints) |> MapSet.size()
    resolved = MapSet.difference(baseline, current_fingerprints) |> MapSet.size()
    new = MapSet.difference(current_fingerprints, baseline) |> MapSet.size()

    %{
      baseline_size: MapSet.size(baseline),
      still_present: still_present,
      resolved: resolved,
      new: new,
      current: MapSet.size(current_fingerprints)
    }
  end

  # --- Private helpers ---

  # Extract a stable identifier from the diagnostic message.
  #
  # We look for module names and function references first since those are
  # the most robust across formatting changes. Priority:
  #
  # 1. `Module.function/arity` — most precise
  # 2. `Module.Name` — module reference
  # 3. Fall back to first "capitalized word" in the message
  defp extract_identifier(message) when is_binary(message) do
    patterns = [
      ~r/([A-Z][A-Za-z0-9_.]*\.\w+\/\d+)/,
      ~r/([A-Z][A-Za-z0-9_]+(?:\.[A-Z][A-Za-z0-9_]+)+)/,
      ~r/([a-z_]+\/\d+)/
    ]

    Enum.find_value(patterns, fn pattern ->
      case Regex.run(pattern, message) do
        [_, capture] -> capture
        _ -> nil
      end
    end)
  end

  defp extract_identifier(_), do: nil

  # Stable short hash of a string for fingerprinting.
  defp stable_hash(str) do
    :erlang.phash2(str)
    |> Integer.to_string(16)
    |> String.downcase()
  end

  # Normalize a file path so it's stable across absolute/relative forms.
  defp normalize_file(file) when is_binary(file) do
    case File.cwd() do
      {:ok, cwd} -> Path.relative_to(file, cwd)
      _ -> file
    end
  end

  defp normalize_file(file), do: to_string(file)

  defp format_timestamp do
    {{y, mo, d}, {h, mi, _s}} = :calendar.local_time()
    :io_lib.format("~4..0w-~2..0w-~2..0w ~2..0w:~2..0w", [y, mo, d, h, mi]) |> to_string()
  end
end
