defmodule Archdo.Rules.Testing.TestTimeoutInfinityTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Testing.TestTimeoutInfinity

  describe "analyze/3" do
    test "flags @tag timeout: :infinity" do
      code = ~S"""
      defmodule MyApp.SlowTest do
        use ExUnit.Case

        @tag timeout: :infinity
        test "long-running case" do
          assert :ok == MyApp.run()
        end
      end
      """

      diags =
        assert_flagged(TestTimeoutInfinity, code, file: "test/slow_test.exs")

      assert hd(diags).rule_id == "7.34"
    end

    test "flags @moduletag timeout: :infinity" do
      code = ~S"""
      defmodule MyApp.SlowTest do
        use ExUnit.Case
        @moduletag timeout: :infinity
      end
      """

      assert_flagged(TestTimeoutInfinity, code, file: "test/slow_test.exs")
    end

    test "ignores @tag timeout: 60_000" do
      code = ~S"""
      defmodule MyApp.SlowTest do
        use ExUnit.Case

        @tag timeout: 60_000
        test "case" do
          assert :ok == MyApp.run()
        end
      end
      """

      assert_clean(TestTimeoutInfinity, code, file: "test/slow_test.exs")
    end

    test "skips non-test files" do
      code = ~S"""
      defmodule MyApp.Slow do
        @timeout :infinity
        def call, do: :ok
      end
      """

      assert_clean(TestTimeoutInfinity, code, file: "lib/my_app/slow.ex")
    end
  end
end
