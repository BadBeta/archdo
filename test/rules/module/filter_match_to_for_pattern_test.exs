defmodule Archdo.Rules.Module.FilterMatchToForPatternTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.FilterMatchToForPattern

  test "fires on `Enum.filter(coll, &match?({:ok, _}, &1)) |> Enum.map(fn {:ok, v} -> v end)`" do
    code = ~S"""
    defmodule MyApp.Results do
      def successes(results) do
        results
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, v} -> v end)
      end
    end
    """

    diags = assert_flagged(FilterMatchToForPattern, code)
    assert hd(diags).rule_id == "6.74"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "for"
  end

  test "does NOT fire on `for {:ok, v} <- results, do: v` (already idiomatic)" do
    code = ~S"""
    defmodule MyApp.Results do
      def successes(results) do
        for {:ok, v} <- results, do: v
      end
    end
    """

    assert_clean(FilterMatchToForPattern, code)
  end

  test "does NOT fire on a generic filter+map without match? (different idiom)" do
    code = ~S"""
    defmodule MyApp.Numbers do
      def positives(nums) do
        nums |> Enum.filter(&(&1 > 0)) |> Enum.map(&(&1 * 2))
      end
    end
    """

    assert_clean(FilterMatchToForPattern, code)
  end
end
