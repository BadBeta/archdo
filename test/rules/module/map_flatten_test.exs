defmodule Archdo.Rules.Module.MapFlattenTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.MapFlatten

  test "fires on `Enum.map(coll, f) |> List.flatten()`" do
    code = ~S"""
    defmodule MyApp.Tags do
      def all_tags(posts) do
        posts |> Enum.map(& &1.tags) |> List.flatten()
      end
    end
    """

    diags = assert_flagged(MapFlatten, code)
    assert hd(diags).rule_id == "6.69"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "flat_map"
  end

  test "does NOT fire on Enum.flat_map (already idiomatic)" do
    code = ~S"""
    defmodule MyApp.Tags do
      def all_tags(posts), do: Enum.flat_map(posts, & &1.tags)
    end
    """

    assert_clean(MapFlatten, code)
  end

  test "does NOT fire on Enum.map alone (no List.flatten step)" do
    code = ~S"""
    defmodule MyApp.Tags do
      def first_tags(posts), do: Enum.map(posts, & &1.tags)
    end
    """

    assert_clean(MapFlatten, code)
  end
end
