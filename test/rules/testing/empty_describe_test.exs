defmodule Archdo.Rules.Testing.EmptyDescribeTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Testing.EmptyDescribe

  describe "analyze/3" do
    test "flags describe block with no tests" do
      code = ~S"""
      defmodule MyApp.UserTest do
        use ExUnit.Case

        describe "create/1" do
        end
      end
      """

      diags = assert_flagged(EmptyDescribe, code, file: "test/user_test.exs")
      assert hd(diags).rule_id == "7.24"
      assert hd(diags).message =~ "create/1"
    end

    test "allows describe block containing tests" do
      code = ~S"""
      defmodule MyApp.UserTest do
        use ExUnit.Case

        describe "create/1" do
          test "creates a user" do
            assert {:ok, _} = User.create(%{name: "Alice"})
          end
        end
      end
      """

      assert_clean(EmptyDescribe, code, file: "test/user_test.exs")
    end

    test "skips non-test files" do
      code = ~S"""
      defmodule MyApp.Docs do
        def describe(name) do
        end
      end
      """

      assert_clean(EmptyDescribe, code, file: "lib/my_app/docs.ex")
    end

    test "flags multiple empty describe blocks" do
      code = ~S"""
      defmodule MyApp.UserTest do
        use ExUnit.Case

        describe "create/1" do
        end

        describe "update/2" do
        end
      end
      """

      diags = assert_flagged(EmptyDescribe, code, file: "test/user_test.exs")
      assert length(diags) == 2
    end
  end
end
