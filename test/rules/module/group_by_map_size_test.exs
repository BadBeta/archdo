defmodule Archdo.Rules.Module.GroupByMapSizeTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.GroupByMapSize

  test "fires on `Enum.group_by |> Map.new(fn {k, v} -> {k, length(v)} end)`" do
    code = ~S"""
    defmodule MyApp.Stats do
      def by_category(items) do
        items
        |> Enum.group_by(& &1.category)
        |> Map.new(fn {k, v} -> {k, length(v)} end)
      end
    end
    """

    diags = assert_flagged(GroupByMapSize, code)
    assert hd(diags).rule_id == "6.66"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "frequencies"
  end

  test "does NOT fire on Enum.frequencies_by (already idiomatic)" do
    code = ~S"""
    defmodule MyApp.Stats do
      def by_category(items), do: Enum.frequencies_by(items, & &1.category)
    end
    """

    assert_clean(GroupByMapSize, code)
  end

  test "does NOT fire on Enum.group_by alone (no length-counting transform)" do
    code = ~S"""
    defmodule MyApp.Stats do
      def by_category(items), do: Enum.group_by(items, & &1.category)
    end
    """

    assert_clean(GroupByMapSize, code)
  end
end
