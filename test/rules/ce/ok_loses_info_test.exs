defmodule Archdo.Rules.CE.OkLosesInfoTest do
  use Archdo.RuleCase

  alias Archdo.Rules.CE.OkLosesInfo

  test "fires when last expression returns {:ok, value} but function returns :ok" do
    code = ~S"""
    defmodule MyApp.Accounts do
      def create_user(attrs) do
        {:ok, _user} = Repo.insert(%User{} |> User.changeset(attrs))
        :ok
      end
    end
    """

    diags = assert_flagged(OkLosesInfo, code)
    assert hd(diags).rule_id == "CE-50"
    assert hd(diags).severity == :warning
    assert hd(diags).message =~ "create_user"
  end

  test "does NOT fire when function returns the {:ok, value} tuple" do
    code = ~S"""
    defmodule MyApp.Accounts do
      def create_user(attrs), do: Repo.insert(%User{} |> User.changeset(attrs))
    end
    """

    assert_clean(OkLosesInfo, code)
  end

  test "does NOT fire when @archdo_fire_and_forget marker is present" do
    code = ~S"""
    defmodule MyApp.Cache do
      @archdo_fire_and_forget true
      def invalidate(key) do
        :ets.delete(:my_cache, key)
        :ok
      end
    end
    """

    assert_clean(OkLosesInfo, code)
  end

  test "does NOT fire when the function does no meaningful work" do
    # Trivial functions returning :ok with no preceding richer-result
    # call are pure side-effect or no-op; nothing to lose.
    code = ~S"""
    defmodule MyApp.Noop do
      def ping, do: :ok
    end
    """

    assert_clean(OkLosesInfo, code)
  end
end
