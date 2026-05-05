defmodule Archdo.Rules.Module.MapToMapSetTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.MapToMapSet

  test "fires on `Enum.map(coll, f) |> MapSet.new()`" do
    code = ~S"""
    defmodule MyApp.Ids do
      def unique_user_ids(events) do
        events |> Enum.map(& &1.user_id) |> MapSet.new()
      end
    end
    """

    diags = assert_flagged(MapToMapSet, code)
    assert hd(diags).rule_id == "6.70"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "MapSet.new"
  end

  test "does NOT fire on `MapSet.new(coll, transformer)` (already idiomatic)" do
    code = ~S"""
    defmodule MyApp.Ids do
      def unique_user_ids(events), do: MapSet.new(events, & &1.user_id)
    end
    """

    assert_clean(MapToMapSet, code)
  end

  test "does NOT fire on Enum.map alone (no MapSet collector)" do
    code = ~S"""
    defmodule MyApp.Ids do
      def user_ids(events), do: Enum.map(events, & &1.user_id)
    end
    """

    assert_clean(MapToMapSet, code)
  end
end
