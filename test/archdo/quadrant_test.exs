defmodule Archdo.QuadrantTest do
  use ExUnit.Case, async: true

  alias Archdo.{Quadrant, QuadrantTestRule}

  setup do
    # Each test injects its own cells; reset on exit so tests don't leak.
    on_exit(fn -> Process.delete(:quadrant_test_cells) end)
    :ok
  end

  describe "evaluate/4 — empty / no-finding paths" do
    test "returns [] when axes/3 returns []" do
      Process.put(:quadrant_test_cells, [])
      assert Quadrant.evaluate(QuadrantTestRule, "lib/x.ex", nil, []) == []
    end

    test "returns [] when every cell is :no_finding" do
      Process.put(:quadrant_test_cells, [
        {{:low, :stable}, %{}},
        {{:high, :stable}, %{}}
      ])

      assert Quadrant.evaluate(QuadrantTestRule, "lib/x.ex", nil, []) == []
    end

    test "treats a cell missing from the policy as :no_finding (no crash)" do
      Process.put(:quadrant_test_cells, [{{:unknown, :unknown}, %{}}])
      assert Quadrant.evaluate(QuadrantTestRule, "lib/x.ex", nil, []) == []
    end
  end

  describe "evaluate/4 — fire paths" do
    test "returns one Diagnostic for one :fire cell" do
      Process.put(:quadrant_test_cells, [{{:high, :volatile}, %{line: 42}}])

      assert [%Archdo.Diagnostic{} = diag] =
               Quadrant.evaluate(QuadrantTestRule, "lib/x.ex", nil, [])

      assert diag.rule_id == "QTEST.fire-hv"
      assert diag.severity == :warning
      assert diag.title == "high-volatile actionable"
      assert diag.line == 42
    end

    test "returns multiple Diagnostics for multiple :fire cells" do
      Process.put(:quadrant_test_cells, [
        {{:high, :volatile}, %{line: 1}},
        {{:low, :volatile}, %{line: 2}},
        {{:high, :stable}, %{line: 3}}
      ])

      diags = Quadrant.evaluate(QuadrantTestRule, "lib/x.ex", nil, [])
      assert length(diags) == 2
      assert Enum.find(diags, &(&1.rule_id == "QTEST.fire-hv"))
      assert Enum.find(diags, &(&1.rule_id == "QTEST.fire-lv"))
      refute Enum.find(diags, &(&1.line == 3)),
             "the high/stable cell is :no_finding and must not emit a diagnostic"
    end

    test "severity in the Diagnostic comes from the policy entry" do
      Process.put(:quadrant_test_cells, [{{:low, :volatile}, %{}}])
      [diag] = Quadrant.evaluate(QuadrantTestRule, "lib/x.ex", nil, [])
      assert diag.severity == :info
    end

    test "evidence map is threaded through to finding_for/4" do
      Process.put(:quadrant_test_cells, [{{:high, :volatile}, %{line: 99}}])
      [diag] = Quadrant.evaluate(QuadrantTestRule, "lib/x.ex", nil, [])
      assert diag.line == 99
    end
  end

  describe "cells/1 helper" do
    test "enumerates the cartesian product of two axis value lists" do
      assert MapSet.new(Quadrant.cells([:high, :low], [:volatile, :stable])) ==
               MapSet.new([
                 {:high, :volatile},
                 {:high, :stable},
                 {:low, :volatile},
                 {:low, :stable}
               ])
    end

    test "returns [] when either axis is empty" do
      assert Quadrant.cells([], [:a, :b]) == []
      assert Quadrant.cells([:a, :b], []) == []
    end
  end

  describe "fire?/1 predicate" do
    test "true for {:fire, _, _, _} actions" do
      assert Quadrant.fire?({:fire, :warning, "X", "title"})
    end

    test "false for :no_finding" do
      refute Quadrant.fire?(:no_finding)
    end
  end

  describe "axes_summary/2 — for --metrics column" do
    test "counts cells per outcome (fire vs no_finding) given a policy" do
      cells = [
        {{:high, :volatile}, %{}},
        {{:high, :volatile}, %{}},
        {{:low, :volatile}, %{}},
        {{:low, :stable}, %{}},
        {{:high, :stable}, %{}}
      ]

      summary = Quadrant.axes_summary(cells, QuadrantTestRule.policy())

      assert summary[{:high, :volatile}] == 2
      assert summary[{:low, :volatile}] == 1
      assert summary[{:low, :stable}] == 1
      assert summary[{:high, :stable}] == 1
    end
  end

  describe "end-to-end via Archdo.Rule.analyze/3" do
    test "synthetic rule integrates cleanly through the rule callback" do
      Process.put(:quadrant_test_cells, [{{:high, :volatile}, %{line: 7}}])

      diags = QuadrantTestRule.analyze("lib/example.ex", nil, [])

      assert [%Archdo.Diagnostic{rule_id: "QTEST.fire-hv", line: 7}] = diags
    end
  end
end
