defmodule Archdo.Rules.Module.InefficientFilterTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.InefficientFilter

  test "fires on `Repo.all(...) |> Enum.filter(&(&1.field))` — could be DB-side `where`" do
    code = ~S"""
    defmodule MyApp.Users do
      alias MyApp.Repo
      alias MyApp.User

      def list_active do
        Repo.all(User) |> Enum.filter(&(&1.active))
      end
    end
    """

    diags = assert_flagged(InefficientFilter, code)
    assert hd(diags).rule_id == "6.57"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "filter"
  end

  test "does NOT fire when the filter callback is a function reference (Elixir-side check)" do
    # `&MyApp.eligible?/1` is a remote-function capture — the rule
    # can't tell whether the predicate is DB-translatable. Skip.
    code = ~S"""
    defmodule MyApp.Users do
      alias MyApp.Repo
      alias MyApp.User

      def list_eligible do
        Repo.all(User) |> Enum.filter(&MyApp.eligible?/1)
      end
    end
    """

    assert_clean(InefficientFilter, code)
  end

  test "does NOT fire on a non-Repo source (`[1, 2, 3] |> Enum.filter(...)`)" do
    code = ~S"""
    defmodule MyApp.Pure do
      def positive(list) do
        list |> Enum.filter(&(&1 > 0))
      end
    end
    """

    assert_clean(InefficientFilter, code)
  end
end
