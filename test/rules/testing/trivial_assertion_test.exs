defmodule Archdo.Rules.Testing.TrivialAssertionTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Testing.TrivialAssertion

  describe "analyze/3" do
    test "flags assert true" do
      code = ~S"""
      defmodule MyApp.UserTest do
        use ExUnit.Case

        test "placeholder" do
          assert true
        end
      end
      """

      diags = assert_flagged(TrivialAssertion, code, file: "test/user_test.exs")
      assert hd(diags).rule_id == "7.10"
    end

    test "allows assert with real expression" do
      code = ~S"""
      defmodule MyApp.UserTest do
        use ExUnit.Case

        test "creates user" do
          assert {:ok, user} = create_user()
          assert user.name == "test"
        end
      end
      """

      assert_clean(TrivialAssertion, code, file: "test/user_test.exs")
    end
  end
end
