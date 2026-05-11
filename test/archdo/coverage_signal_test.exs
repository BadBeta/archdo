defmodule Archdo.CoverageSignalTest do
  use ExUnit.Case, async: true

  alias Archdo.{CoverageSignal, Diagnostic}

  @required title: "t", message: "m", why: "w", line: 1

  defp diag(rule_id, file), do: Diagnostic.warning(rule_id, [{:file, file} | @required])

  describe "annotate/3 — coverage-rate downgrade" do
    test "downgrades a rule firing on >=30% of analyzed units to :medium" do
      # Rule X fires on 4 of 10 files (40%).
      diags = for i <- 1..4, do: diag("X.1", "lib/m#{i}.ex")
      {annotated, notes} = CoverageSignal.annotate(diags, 10)

      assert Enum.all?(annotated, &(&1.confidence == :medium))
      assert [%{rule_id: "X.1", coverage_rate: rate, units_affected: 4, total_units: 10}] = notes
      assert_in_delta rate, 0.4, 0.001
    end

    test "leaves a rule firing on <30% of units at :high" do
      diags = for i <- 1..2, do: diag("Y.1", "lib/m#{i}.ex")
      {annotated, notes} = CoverageSignal.annotate(diags, 10)

      assert Enum.all?(annotated, &(&1.confidence == :high))
      assert notes == []
    end

    test "handles multiple rules independently" do
      # Rule A: 4/10 (downgrade). Rule B: 1/10 (keep).
      a = for i <- 1..4, do: diag("A.1", "lib/a#{i}.ex")
      b = [diag("B.1", "lib/b1.ex")]
      {annotated, notes} = CoverageSignal.annotate(a ++ b, 10)

      grouped = Enum.group_by(annotated, & &1.rule_id)
      assert Enum.all?(grouped["A.1"], &(&1.confidence == :medium))
      assert Enum.all?(grouped["B.1"], &(&1.confidence == :high))
      assert [%{rule_id: "A.1"}] = notes
    end

    test "counts DISTINCT files per rule (not findings)" do
      # 5 findings but only 2 distinct files — 2/10 = 20%, not 50%.
      diags = [
        diag("Z.1", "lib/a.ex"),
        diag("Z.1", "lib/a.ex"),
        diag("Z.1", "lib/a.ex"),
        diag("Z.1", "lib/b.ex"),
        diag("Z.1", "lib/b.ex")
      ]

      {annotated, notes} = CoverageSignal.annotate(diags, 10)
      assert Enum.all?(annotated, &(&1.confidence == :high))
      assert notes == []
    end

    test "zero analyzed units → no downgrade, no notes (avoid divide-by-zero)" do
      diags = [diag("Q.1", "lib/a.ex")]
      assert {^diags, []} = CoverageSignal.annotate(diags, 0)
    end

    test "empty diagnostic list → empty notes" do
      assert {[], []} = CoverageSignal.annotate([], 10)
    end

    test "respects explicit threshold opt" do
      diags = for i <- 1..2, do: diag("P.1", "lib/m#{i}.ex")
      # 2/10 = 20%, below default 30%. With threshold 0.10 it should downgrade.
      {annotated, notes} = CoverageSignal.annotate(diags, 10, threshold: 0.10)
      assert Enum.all?(annotated, &(&1.confidence == :medium))
      assert [%{rule_id: "P.1"}] = notes
    end

    test "preserves existing :low or :medium — never upgrades" do
      d_low = %{diag("R.1", "lib/a.ex") | confidence: :low}
      # Single low-confidence finding, well below threshold — must stay :low.
      assert {[%{confidence: :low}], []} = CoverageSignal.annotate([d_low], 10)
    end
  end
end
