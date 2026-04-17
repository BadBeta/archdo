defmodule Archdo.Rules.Testing.GenericTestNamesTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Testing.GenericTestNames

  describe "analyze/3" do
    test "flags test named 'it works'" do
      code = ~S"""
      defmodule MyApp.UserTest do
        use ExUnit.Case, async: true

        test "it works" do
          assert true
        end
      end
      """

      diags = assert_flagged(GenericTestNames, code, file: "test/user_test.exs")
      assert hd(diags).rule_id == "7.17"
    end

    test "flags test named 'test 1'" do
      code = ~S"""
      defmodule MyApp.UserTest do
        use ExUnit.Case, async: true

        test "test_1" do
          assert true
        end
      end
      """

      assert_flagged(GenericTestNames, code, file: "test/user_test.exs")
    end

    test "allows descriptive test name" do
      code = ~S"""
      defmodule MyApp.UserTest do
        use ExUnit.Case, async: true

        test "creates user with valid attributes" do
          assert {:ok, _} = create_user(%{name: "test"})
        end
      end
      """

      assert_clean(GenericTestNames, code, file: "test/user_test.exs")
    end

    test "skips non-test files" do
      code = ~S"""
      defmodule MyApp.Example do
        def test("works"), do: true
      end
      """

      assert_clean(GenericTestNames, code, file: "lib/example.ex")
    end
  end
end
