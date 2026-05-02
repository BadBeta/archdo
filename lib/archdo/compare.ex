defmodule Archdo.Compare do
  @moduledoc false

  # §§ elixir-planning: §6 — M30e Comparative scoring scaffold.
  # `mix archdo --compare-with path1,path2,...` runs analysis on the
  # main project + each comparison path and prints a side-by-side
  # table of rule counts. Lets a project see itself relative to peers
  # (Phoenix / Ecto / Oban / curated cohort) — a peer-axis substitute
  # for the missing time-axis trend.
  #
  # v1 scope: paths are user-supplied (no cohort fetching). Future:
  # cache curated cohort, ship with releases, archetype-aware default.

  alias Archdo.Diagnostic

  @type aggregate :: %{{String.t(), Diagnostic.severity()} => non_neg_integer()}

  @type table :: %{
          codebases: [String.t()],
          rows: %{{String.t(), Diagnostic.severity()} => %{String.t() => non_neg_integer()}}
        }

  @doc """
  Aggregate a list of diagnostics into per-`{rule_id, severity}`
  counts.
  """
  @spec aggregate([Diagnostic.t()]) :: aggregate()
  def aggregate(diagnostics) do
    Enum.reduce(diagnostics, %{}, fn d, acc ->
      Map.update(acc, {d.rule_id, d.severity}, 1, &(&1 + 1))
    end)
  end

  @doc """
  Run comparison analysis: analyze each path with `Archdo.run/2`,
  return per-codebase aggregates as `[{label, aggregate}, ...]`. The
  first entry is the main project; the rest are comparison codebases.

  Codebase labels are derived from the path's last segment.
  """
  @spec run([String.t()], [String.t()], keyword()) :: [{String.t(), aggregate()}]
  def run(main_paths, compare_paths, opts \\ []) do
    main_label = label_for(main_paths)
    main_diags = Archdo.run(main_paths, opts)
    main_entry = {main_label, aggregate(main_diags)}

    compare_entries =
      Enum.map(compare_paths, fn path ->
        label = label_for([path])
        diags = Archdo.run([path], opts)
        {label, aggregate(diags)}
      end)

    [main_entry | compare_entries]
  end

  # Label is the project name, not the lib subdir. For "/tmp/oban/lib"
  # we want "oban", not "lib". When the basename IS already meaningful
  # (e.g., "src", "apps/foo"), fall back to a parent-aware label.
  defp label_for([path | _]) do
    base = Path.basename(path)

    case base in ["lib", "src", "apps", ""] do
      true ->
        path |> Path.expand() |> Path.dirname() |> Path.basename() |> default_label()

      false ->
        default_label(base)
    end
  end

  defp label_for([]), do: "project"

  defp default_label(""), do: "project"
  defp default_label(name), do: name

  @doc """
  Merge per-codebase aggregates into a side-by-side comparison table.
  Every codebase appears in every row, zero-filled when the codebase
  didn't fire that rule.
  """
  @spec merge([{String.t(), aggregate()}]) :: table()
  def merge(per_codebase) do
    codebases = Enum.map(per_codebase, fn {label, _} -> label end)
    all_keys = collect_keys(per_codebase)

    rows =
      Map.new(all_keys, fn key ->
        per_codebase_count =
          Map.new(per_codebase, fn {label, agg} -> {label, Map.get(agg, key, 0)} end)

        {key, per_codebase_count}
      end)

    %{codebases: codebases, rows: rows}
  end

  defp collect_keys(per_codebase) do
    per_codebase
    |> Enum.flat_map(fn {_, agg} -> Map.keys(agg) end)
    |> Enum.uniq()
  end

  @doc """
  Render a comparison table as a readable plain-text string.

  Columns: rule_id, severity, then one count column per codebase.
  Rows sorted by rule_id then severity.
  """
  @spec format(table()) :: String.t()
  def format(%{codebases: codebases, rows: rows}) do
    sorted_rows =
      rows
      |> Enum.sort_by(fn {{rule_id, severity}, _} -> {rule_id, severity_order(severity)} end)

    rule_w = max_width(["rule" | Enum.map(sorted_rows, fn {{r, _}, _} -> r end)])
    sev_w = max_width(["sev" | Enum.map(sorted_rows, fn {{_, s}, _} -> Atom.to_string(s) end)])
    code_widths = Enum.map(codebases, &max(String.length(&1), 5))

    header =
      [pad("rule", rule_w), pad("sev", sev_w) | Enum.zip(codebases, code_widths) |> Enum.map(fn {c, w} -> pad(c, w) end)]
      |> Enum.join("  ")

    sep = String.duplicate("-", String.length(header))

    body_lines =
      Enum.map(sorted_rows, fn {{rule_id, severity}, counts} ->
        cells =
          Enum.zip(codebases, code_widths)
          |> Enum.map(fn {c, w} -> pad(Integer.to_string(Map.get(counts, c, 0)), w) end)

        [pad(rule_id, rule_w), pad(Atom.to_string(severity), sev_w) | cells]
        |> Enum.join("  ")
      end)

    Enum.join(["", "Comparison report", sep, header, sep | body_lines] ++ [""], "\n")
  end

  defp max_width(strings),
    do: strings |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end)

  defp pad(s, width) when is_binary(s) do
    s <> String.duplicate(" ", max(width - String.length(s), 0))
  end

  defp severity_order(:error), do: 0
  defp severity_order(:warning), do: 1
  defp severity_order(:info), do: 2
  defp severity_order(:nitpick), do: 3
end
