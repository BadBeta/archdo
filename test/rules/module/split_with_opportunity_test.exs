defmodule Archdo.Rules.Module.SplitWithOpportunityTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.SplitWithOpportunity

  test "fires on `{Enum.filter(coll, pred), Enum.reject(coll, pred)}` — same coll, same pred" do
    code = ~S"""
    defmodule MyApp.Partition do
      def by_active(users) do
        {Enum.filter(users, & &1.active), Enum.reject(users, & &1.active)}
      end
    end
    """

    diags = assert_flagged(SplitWithOpportunity, code)
    assert hd(diags).rule_id == "6.67"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "split_with"
  end

  test "does NOT fire on Enum.split_with (already idiomatic)" do
    code = ~S"""
    defmodule MyApp.Partition do
      def by_active(users), do: Enum.split_with(users, & &1.active)
    end
    """

    assert_clean(SplitWithOpportunity, code)
  end

  test "does NOT fire when filter and reject use different predicates" do
    code = ~S"""
    defmodule MyApp.Partition do
      def split(users) do
        {Enum.filter(users, & &1.active), Enum.reject(users, & &1.banned)}
      end
    end
    """

    assert_clean(SplitWithOpportunity, code)
  end
end
