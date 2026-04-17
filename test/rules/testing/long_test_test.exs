defmodule Archdo.Rules.Testing.LongTestTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Testing.LongTest

  describe "analyze/3" do
    test "flags test with very large body" do
      body_lines = Enum.map_join(1..80, "\n", fn i -> "      assert #{i} == #{i}" end)

      code = """
      defmodule MyApp.BigTestTest do
        use ExUnit.Case

        test "does too much" do
      #{body_lines}
        end
      end
      """

      diags = assert_flagged(LongTest, code, file: "test/big_test_test.exs")
      assert hd(diags).rule_id == "7.12"
    end

    test "allows short test body" do
      code = ~S"""
      defmodule MyApp.SimpleTest do
        use ExUnit.Case

        test "creates user" do
          assert {:ok, user} = create()
          assert user.name == "test"
        end
      end
      """

      assert_clean(LongTest, code, file: "test/simple_test.exs")
    end
  end
end
