defmodule Archdo.Rules.Module.MapUpdateOpportunityTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.MapUpdateOpportunity

  test "fires on `Map.put(m, :k, fun(Map.get(m, :k)))` — fetch-modify-put" do
    code = ~S"""
    defmodule MyApp.Counter do
      def inc(map, key) do
        Map.put(map, key, Map.get(map, key, 0) + 1)
      end
    end
    """

    diags = assert_flagged(MapUpdateOpportunity, code)
    assert hd(diags).rule_id == "6.82"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "Map.update"
  end

  test "does NOT fire on Map.update (already idiomatic)" do
    code = ~S"""
    defmodule MyApp.Counter do
      def inc(map, key), do: Map.update(map, key, 1, &(&1 + 1))
    end
    """

    assert_clean(MapUpdateOpportunity, code)
  end

  test "does NOT fire on a Map.put that doesn't reference the same key's get" do
    code = ~S"""
    defmodule MyApp.Build do
      def with_active(map), do: Map.put(map, :active, true)
    end
    """

    assert_clean(MapUpdateOpportunity, code)
  end
end
