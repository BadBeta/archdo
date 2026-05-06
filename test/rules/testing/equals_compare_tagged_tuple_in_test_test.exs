defmodule Archdo.Rules.Testing.EqualsCompareTaggedTupleInTestTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Testing.EqualsCompareTaggedTupleInTest

  describe "analyze/3" do
    test "flags assert {:ok, value} == call" do
      code = ~S"""
      defmodule MyApp.UserTest do
        use ExUnit.Case

        test "creates user" do
          assert {:ok, %User{email: "a@b.com"}} == Accounts.create_user(%{email: "a@b.com"})
        end
      end
      """

      diags =
        assert_flagged(EqualsCompareTaggedTupleInTest, code, file: "test/user_test.exs")

      assert hd(diags).rule_id == "7.32"
    end

    test "flags assert {:error, reason} == call" do
      code = ~S"""
      defmodule MyApp.UserTest do
        use ExUnit.Case

        test "rejects bad email" do
          assert {:error, :invalid_email} == Accounts.create_user(%{email: ""})
        end
      end
      """

      assert_flagged(EqualsCompareTaggedTupleInTest, code, file: "test/user_test.exs")
    end

    test "ignores assert {:ok, _} = call (pattern match — already idiomatic)" do
      code = ~S"""
      defmodule MyApp.UserTest do
        use ExUnit.Case

        test "creates user" do
          assert {:ok, %User{}} = Accounts.create_user(%{email: "a@b.com"})
        end
      end
      """

      assert_clean(EqualsCompareTaggedTupleInTest, code, file: "test/user_test.exs")
    end

    test "ignores assert x == y where x is not a tagged tuple" do
      code = ~S"""
      defmodule MyApp.UserTest do
        use ExUnit.Case

        test "computes total" do
          assert 42 == MyApp.calc()
          assert "hello" == MyApp.greet()
        end
      end
      """

      assert_clean(EqualsCompareTaggedTupleInTest, code, file: "test/user_test.exs")
    end

    test "skips non-test files" do
      code = ~S"""
      defmodule MyApp.User do
        def check, do: {:ok, 1} == fetch()
      end
      """

      assert_clean(EqualsCompareTaggedTupleInTest, code, file: "lib/my_app/user.ex")
    end
  end
end
