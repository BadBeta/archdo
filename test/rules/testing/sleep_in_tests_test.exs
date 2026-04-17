defmodule Archdo.Rules.Testing.SleepInTestsTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Testing.SleepInTests

  describe "analyze/3" do
    test "flags Process.sleep in test file" do
      code = ~S"""
      defmodule MyApp.WorkerTest do
        use ExUnit.Case

        test "sends message" do
          send(self(), :hello)
          Process.sleep(100)
          assert_received :hello
        end
      end
      """

      diags = assert_flagged(SleepInTests, code, file: "test/worker_test.exs")
      assert hd(diags).rule_id == "7.5"
    end

    test "flags :timer.sleep in test file" do
      code = ~S"""
      defmodule MyApp.WorkerTest do
        use ExUnit.Case

        test "waits for work" do
          :timer.sleep(500)
          assert true
        end
      end
      """

      assert_flagged(SleepInTests, code, file: "test/worker_test.exs")
    end

    test "allows test without sleep" do
      code = ~S"""
      defmodule MyApp.WorkerTest do
        use ExUnit.Case

        test "sends message" do
          send(self(), :hello)
          assert_receive :hello, 100
        end
      end
      """

      assert_clean(SleepInTests, code, file: "test/worker_test.exs")
    end

    test "skips non-test files" do
      code = ~S"""
      defmodule MyApp.Poller do
        def poll do
          Process.sleep(1000)
          :ok
        end
      end
      """

      assert_clean(SleepInTests, code, file: "lib/my_app/poller.ex")
    end
  end
end
