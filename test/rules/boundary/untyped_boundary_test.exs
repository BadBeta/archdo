defmodule Archdo.Rules.Boundary.UntypedBoundaryTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Boundary.UntypedBoundary

  describe "analyze/3" do
    test "flags @spec returning untyped map() at context boundary" do
      code = ~S"""
      defmodule MyApp.Accounts do
        @spec get_user(integer()) :: map()
        def get_user(id), do: %{id: id, name: "test"}
      end
      """

      diags = assert_flagged(UntypedBoundary, code, file: "/project/lib/my_app/accounts.ex")
      assert hd(diags).rule_id == "1.12"
      assert hd(diags).message =~ "map()"
    end

    test "allows typed @spec returns" do
      code = ~S"""
      defmodule MyApp.Accounts do
        @spec get_user(integer()) :: %MyApp.User{}
        def get_user(id), do: %MyApp.User{id: id}
      end
      """

      assert_clean(UntypedBoundary, code, file: "/project/lib/my_app/accounts.ex")
    end

    test "ignores non-context files" do
      code = ~S"""
      defmodule MyApp.Accounts.UserQuery do
        @spec base_query() :: map()
        def base_query, do: %{}
      end
      """

      assert_clean(UntypedBoundary, code, file: "/project/lib/my_app/accounts/user_query.ex")
    end
  end
end
