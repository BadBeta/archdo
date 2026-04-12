defmodule Archdo.Rules.Testing.RepoInTestsTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Testing.RepoInTests

  test "flags Repo.insert in test file" do
    code = ~S"""
    defmodule MyApp.AccountsTest do
      use ExUnit.Case

      test "creates user" do
        MyApp.Repo.insert!(%MyApp.User{name: "Test"})
      end
    end
    """

    diags = assert_flagged(RepoInTests, code, file: "test/my_app/accounts_test.exs")
    assert hd(diags).message =~ "Repo.insert!"
  end

  test "ignores support files" do
    code = ~S"""
    defmodule MyApp.Factory do
      def create_user(attrs) do
        MyApp.Repo.insert!(%MyApp.User{name: "Test"})
      end
    end
    """

    assert_clean(RepoInTests, code, file: "test/support/factory.ex")
  end

  test "ignores production code" do
    code = ~S"""
    defmodule MyApp.Accounts do
      def create(attrs), do: MyApp.Repo.insert!(%MyApp.User{})
    end
    """

    assert_clean(RepoInTests, code, file: "lib/my_app/accounts.ex")
  end
end
