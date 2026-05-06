defmodule Archdo.Rules.Testing.AssertReceiveNoTimeoutTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Testing.AssertReceiveNoTimeout

  describe "analyze/3" do
    test "flags assert_receive without timeout" do
      code = ~S"""
      defmodule MyApp.WorkerTest do
        use ExUnit.Case

        test "broadcasts result" do
          MyApp.Worker.run()
          assert_receive {:done, _}
        end
      end
      """

      diags =
        assert_flagged(AssertReceiveNoTimeout, code, file: "test/worker_test.exs")

      assert hd(diags).rule_id == "7.35"
    end

    test "flags refute_receive without timeout" do
      code = ~S"""
      defmodule MyApp.WorkerTest do
        use ExUnit.Case

        test "no error" do
          assert_clean = MyApp.Worker.run()
          refute_receive {:error, _}
        end
      end
      """

      assert_flagged(AssertReceiveNoTimeout, code, file: "test/worker_test.exs")
    end

    test "ignores assert_receive with explicit timeout" do
      code = ~S"""
      defmodule MyApp.WorkerTest do
        use ExUnit.Case

        test "broadcasts result" do
          MyApp.Worker.run()
          assert_receive {:done, _}, 1_000
        end
      end
      """

      assert_clean(AssertReceiveNoTimeout, code, file: "test/worker_test.exs")
    end

    test "skips non-test files" do
      code = ~S"""
      defmodule MyApp.Helper do
        def assert_receive(msg), do: receive do ^msg -> :ok end
      end
      """

      assert_clean(AssertReceiveNoTimeout, code, file: "lib/my_app/helper.ex")
    end
  end
end
