defmodule Archdo.QuadrantMetricsTest do
  use ExUnit.Case, async: true

  alias Archdo.{Quadrant, QuadrantTestRule}

  defmodule PlainRule do
    @moduledoc false
    @behaviour Archdo.Rule
    @impl true
    def id, do: "QMTEST.plain"
    @impl true
    def description, do: "non-quadrant rule"
    @impl true
    def analyze(_, _, _), do: []
  end

  describe "list_rules/1" do
    test "filters a list of rule modules to those implementing Archdo.Quadrant" do
      rules = [PlainRule, QuadrantTestRule]
      assert Quadrant.list_rules(rules) == [QuadrantTestRule]
    end

    test "returns [] when no quadrant rules are present" do
      assert Quadrant.list_rules([PlainRule]) == []
    end
  end

  describe "distribution_for/4" do
    setup do
      on_exit(fn -> Process.delete(:quadrant_test_cells) end)
      :ok
    end

    test "returns the cell-count map for the rule given the supplied evaluation context" do
      Process.put(:quadrant_test_cells, [
        {{:high, :volatile}, %{}},
        {{:high, :volatile}, %{}},
        {{:low, :stable}, %{}}
      ])

      summary =
        Quadrant.distribution_for(QuadrantTestRule, "lib/example.ex", nil, [])

      assert summary[{:high, :volatile}] == 2
      assert summary[{:low, :stable}] == 1
    end
  end
end
