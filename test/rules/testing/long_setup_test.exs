defmodule Archdo.Rules.Testing.LongSetupTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Testing.LongSetup

  describe "analyze/3" do
    test "flags very large setup block" do
      # Generate a setup with many lines (needs >250 AST nodes)
      setup_lines = Enum.map_join(1..100, "\n", fn i -> "      var_#{i} = #{i}" end)

      code = """
      defmodule MyApp.BigSetupTest do
        use ExUnit.Case

        setup do
      #{setup_lines}
          %{result: var_1}
        end

        test "uses setup", %{result: r} do
          assert r == 1
        end
      end
      """

      diags = assert_flagged(LongSetup, code, file: "test/big_setup_test.exs")
      assert hd(diags).rule_id == "7.11"
    end

    test "allows short setup block" do
      code = ~S"""
      defmodule MyApp.SimpleTest do
        use ExUnit.Case

        setup do
          %{x: 1}
        end

        test "ok", %{x: x} do
          assert x == 1
        end
      end
      """

      assert_clean(LongSetup, code, file: "test/simple_test.exs")
    end
  end
end
