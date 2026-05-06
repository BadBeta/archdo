defmodule Archdo.Rules.Module.EctoFragmentStringInterpolationTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.EctoFragmentStringInterpolation

  describe "analyze/3" do
    test "flags fragment with string interpolation" do
      code = ~S"""
      defmodule MyApp.Users do
        import Ecto.Query

        def by_role(role) do
          from u in "users", where: fragment("role = '#{role}'")
        end
      end
      """

      diags =
        assert_flagged(EctoFragmentStringInterpolation, code, file: "lib/my_app/users.ex")

      assert hd(diags).rule_id == "6.92"
    end

    test "ignores fragment with parameter (?)" do
      code = ~S"""
      defmodule MyApp.Users do
        import Ecto.Query

        def by_role(role) do
          from u in "users", where: fragment("role = ?", ^role)
        end
      end
      """

      assert_clean(EctoFragmentStringInterpolation, code, file: "lib/my_app/users.ex")
    end

    test "ignores fragment with plain literal string" do
      code = ~S"""
      defmodule MyApp.Users do
        import Ecto.Query

        def active do
          from u in "users", where: fragment("deleted_at IS NULL")
        end
      end
      """

      assert_clean(EctoFragmentStringInterpolation, code, file: "lib/my_app/users.ex")
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.UsersTest do
        def query(role) do
          from u in "users", where: fragment("role = '#{role}'")
        end
      end
      """

      assert_clean(EctoFragmentStringInterpolation, code, file: "test/users_test.exs")
    end
  end
end
