defmodule Archdo.Rules.Module.FindThenTransformTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.FindThenTransform

  test "fires on `Enum.find(coll, pred) |> transform()`" do
    code = ~S"""
    defmodule MyApp.Lookup do
      def first_active_id(users) do
        users
        |> Enum.find(& &1.active)
        |> id_or_nil()
      end

      defp id_or_nil(nil), do: nil
      defp id_or_nil(u), do: u.id
    end
    """

    diags = assert_flagged(FindThenTransform, code)
    assert hd(diags).rule_id == "6.68"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "find_value"
  end

  test "does NOT fire on Enum.find_value (already idiomatic)" do
    code = ~S"""
    defmodule MyApp.Lookup do
      def first_active_id(users) do
        Enum.find_value(users, fn u -> u.active && u.id end)
      end
    end
    """

    assert_clean(FindThenTransform, code)
  end

  test "does NOT fire on Enum.find without a follow-up transform" do
    code = ~S"""
    defmodule MyApp.Lookup do
      def first_active(users), do: Enum.find(users, & &1.active)
    end
    """

    assert_clean(FindThenTransform, code)
  end
end
