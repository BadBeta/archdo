defmodule Archdo.Rules.Testing.NoAssertionTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Testing.NoAssertion

  describe "analyze/3" do
    test "flags test without any assertion" do
      code = ~S"""
      defmodule MyApp.UserTest do
        use ExUnit.Case

        test "creates user" do
          MyApp.create_user(%{name: "test"})
        end
      end
      """

      diags = assert_flagged(NoAssertion, code, file: "test/user_test.exs")
      assert hd(diags).rule_id == "7.9"
    end

    test "allows test with assert" do
      code = ~S"""
      defmodule MyApp.UserTest do
        use ExUnit.Case

        test "creates user" do
          assert {:ok, _} = MyApp.create_user(%{name: "test"})
        end
      end
      """

      assert_clean(NoAssertion, code, file: "test/user_test.exs")
    end

    test "allows test with assert_receive" do
      code = ~S"""
      defmodule MyApp.WorkerTest do
        use ExUnit.Case

        test "sends message" do
          send(self(), :hello)
          assert_receive :hello
        end
      end
      """

      assert_clean(NoAssertion, code, file: "test/worker_test.exs")
    end
  end
end
