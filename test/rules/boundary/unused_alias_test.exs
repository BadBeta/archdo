defmodule Archdo.Rules.Boundary.UnusedAliasTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Boundary.UnusedAlias

  describe "unused aliases" do
    test "flags an alias that is never referenced" do
      code = ~S"""
      defmodule MyApp.Orders do
        alias MyApp.Accounts.User

        def list_orders, do: []
      end
      """

      diagnostics = assert_flagged(UnusedAlias, code)
      assert [diag] = diagnostics
      assert diag.rule_id == "4.27"
      assert diag.severity == :info
      assert diag.message =~ "User"
      assert diag.message =~ "never referenced"
    end

    test "flags multiple unused aliases" do
      code = ~S"""
      defmodule MyApp.Orders do
        alias MyApp.Accounts.User
        alias MyApp.Payments.Invoice

        def list_orders, do: []
      end
      """

      diagnostics = assert_flagged(UnusedAlias, code)
      assert length(diagnostics) == 2
    end

    test "flags alias with :as that is unused" do
      code = ~S"""
      defmodule MyApp.Orders do
        alias MyApp.Accounts.User, as: U

        def list_orders, do: []
      end
      """

      diagnostics = assert_flagged(UnusedAlias, code)
      assert [diag] = diagnostics
      assert diag.message =~ "U"
    end
  end

  describe "clean code" do
    test "does not flag alias that is used in function body" do
      code = ~S"""
      defmodule MyApp.Orders do
        alias MyApp.Accounts.User

        def get_user(id), do: User.get(id)
      end
      """

      assert_clean(UnusedAlias, code)
    end

    test "does not flag alias used in type specs" do
      code = ~S"""
      defmodule MyApp.Orders do
        alias MyApp.Accounts.User

        @spec get_user(integer()) :: User.t()
        def get_user(id), do: %User{id: id}
      end
      """

      assert_clean(UnusedAlias, code)
    end

    test "does not flag test files" do
      code = ~S"""
      defmodule MyApp.OrdersTest do
        alias MyApp.Accounts.User
      end
      """

      assert_clean(UnusedAlias, code, file: "test/orders_test.exs")
    end
  end

  describe "edge cases" do
    test "does not flag alias used as struct" do
      code = ~S"""
      defmodule MyApp.Orders do
        alias MyApp.Accounts.User

        def new_user, do: %User{name: "test"}
      end
      """

      assert_clean(UnusedAlias, code)
    end

    test "handles alias with deeply nested module" do
      code = ~S"""
      defmodule MyApp.Orders do
        alias MyApp.Accounts.Users.Admin.SuperAdmin

        def list_orders, do: []
      end
      """

      diagnostics = assert_flagged(UnusedAlias, code)
      assert [diag] = diagnostics
      assert diag.message =~ "SuperAdmin"
    end

    test "does not flag when alias is used in pattern match" do
      code = ~S"""
      defmodule MyApp.Orders do
        alias MyApp.Accounts.User

        def handle(%User{} = user), do: user
      end
      """

      assert_clean(UnusedAlias, code)
    end
  end
end
