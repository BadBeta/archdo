defmodule Archdo.Rules.Testing.TestNamingTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Testing.TestNaming

  describe "analyze/3" do
    test "flags test module not ending in Test" do
      code = ~S"""
      defmodule MyApp.UserSpec do
        use ExUnit.Case

        test "works" do
          assert true
        end
      end
      """

      diags = assert_flagged(TestNaming, code, file: "test/user_spec_test.exs")
      assert hd(diags).rule_id == "7.8"
    end

    test "allows properly named test module" do
      code = ~S"""
      defmodule MyApp.UserTest do
        use ExUnit.Case

        test "creates user" do
          assert {:ok, _} = create()
        end
      end
      """

      assert_clean(TestNaming, code, file: "test/user_test.exs")
    end

    test "skips non-test files" do
      code = ~S"""
      defmodule MyApp.User do
        def create, do: :ok
      end
      """

      assert_clean(TestNaming, code, file: "lib/my_app/user.ex")
    end
  end
end
