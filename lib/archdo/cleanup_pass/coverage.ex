defmodule Archdo.CleanupPass.Coverage do
  @moduledoc """
  Coverage matrix for cleanup-guide passes.

  `compute/2` takes the active rule list and the analyzed-run
  diagnostics and returns a map keyed `1..14` with `rule_count` and
  `finding_count` per pass. `format/1` renders that map as a
  human-readable table.

  Used by `mix archdo --pass-coverage`.
  """

  alias Archdo.CleanupPass

  @type entry :: %{rule_count: non_neg_integer(), finding_count: non_neg_integer()}
  @type matrix :: %{(1..14) => entry()}

  @doc "Compute the coverage matrix for the given rule list and diagnostics."
  @spec compute([module()], [Archdo.Diagnostic.t()]) :: matrix()
  def compute(rules, diagnostics) do
    rule_counts = count_rules_per_pass(rules)
    finding_counts = count_findings_per_pass(diagnostics)

    Map.new(1..14, fn pass ->
      {pass,
       %{
         rule_count: Map.get(rule_counts, pass, 0),
         finding_count: Map.get(finding_counts, pass, 0)
       }}
    end)
  end

  defp count_rules_per_pass(rules) do
    rules
    |> Enum.map(&CleanupPass.cleanup_pass_of/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end

  defp count_findings_per_pass(diagnostics) do
    diagnostics
    |> Enum.map(fn d -> CleanupPass.pass_for(d.rule_id) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end

  @doc "Render the matrix as a fixed-width text table."
  @spec format(matrix()) :: String.t()
  def format(matrix) do
    rows =
      for pass <- 1..14 do
        entry = Map.fetch!(matrix, pass)
        label = CleanupPass.pass_label(pass)

        :io_lib.format(
          "  Pass ~2..0w  ~-50s  rules=~3w  findings=~4w~n",
          [pass, truncate(label, 50), entry.rule_count, entry.finding_count]
        )
      end

    header = "\nArchdo — Cleanup Guide Pass Coverage\n\n"
    footer = "\n  (rules without a pass tag are not counted)\n"

    IO.iodata_to_binary([header, rows, footer])
  end

  defp truncate(s, max) when byte_size(s) <= max, do: s
  defp truncate(s, max), do: binary_part(s, 0, max - 1) <> "…"
end
