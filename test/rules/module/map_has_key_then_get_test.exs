defmodule Archdo.Rules.Module.MapHasKeyThenGetTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.MapHasKeyThenGet

  test "fires on `if Map.has_key?(m, k) do Map.get(m, k) ... end`" do
    code = ~S"""
    defmodule MyApp.Cfg do
      def fetch(map, key) do
        if Map.has_key?(map, key) do
          {:ok, Map.get(map, key)}
        else
          :error
        end
      end
    end
    """

    diags = assert_flagged(MapHasKeyThenGet, code)
    assert hd(diags).rule_id == "6.72"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "Map.fetch"
  end

  test "does NOT fire on Map.fetch (already idiomatic)" do
    code = ~S"""
    defmodule MyApp.Cfg do
      def fetch(map, key), do: Map.fetch(map, key)
    end
    """

    assert_clean(MapHasKeyThenGet, code)
  end

  test "does NOT fire when has_key? is used without get on the same map" do
    code = ~S"""
    defmodule MyApp.Cfg do
      def has?(map, key), do: Map.has_key?(map, key)
    end
    """

    assert_clean(MapHasKeyThenGet, code)
  end
end
