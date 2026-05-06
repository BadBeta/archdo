defmodule Archdo.Rules.Module.MapPutChainAsMergeTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.MapPutChainAsMerge

  test "fires on `m |> Map.put(:a, 1) |> Map.put(:b, 2) |> Map.put(:c, 3)` (3+ chained puts)" do
    code = ~S"""
    defmodule MyApp.Build do
      def attrs(base) do
        base
        |> Map.put(:active, true)
        |> Map.put(:created_at, DateTime.utc_now())
        |> Map.put(:source, :web)
      end
    end
    """

    diags = assert_flagged(MapPutChainAsMerge, code)
    assert hd(diags).rule_id == "6.81"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "Map.merge"
  end

  test "does NOT fire on a single Map.put" do
    code = ~S"""
    defmodule MyApp.Build do
      def with_active(map), do: Map.put(map, :active, true)
    end
    """

    assert_clean(MapPutChainAsMerge, code)
  end

  test "does NOT fire on Map.merge (already idiomatic)" do
    code = ~S"""
    defmodule MyApp.Build do
      def attrs(base) do
        Map.merge(base, %{active: true, source: :web})
      end
    end
    """

    assert_clean(MapPutChainAsMerge, code)
  end
end
