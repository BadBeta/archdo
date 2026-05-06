defmodule Archdo.Rules.OTP.SendAfterSelfTickLoopTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.SendAfterSelfTickLoop

  describe "analyze/3" do
    test "flags handle_info(:tick, _) that re-arms via send_after(self(), :tick, _)" do
      code = ~S"""
      defmodule MyApp.Sweeper do
        use GenServer

        def init(_) do
          Process.send_after(self(), :tick, 1_000)
          {:ok, %{}}
        end

        def handle_info(:tick, state) do
          MyApp.Cache.sweep()
          Process.send_after(self(), :tick, 1_000)
          {:noreply, state}
        end
      end
      """

      diags = assert_flagged(SendAfterSelfTickLoop, code, file: "lib/my_app/sweeper.ex")
      assert hd(diags).rule_id == "5.70"
    end

    test "ignores send_after with varying delay (e.g., backoff)" do
      code = ~S"""
      defmodule MyApp.Retry do
        use GenServer

        def handle_info({:retry, attempt}, state) do
          delay = attempt * 1_000
          Process.send_after(self(), {:retry, attempt + 1}, delay)
          {:noreply, state}
        end
      end
      """

      assert_clean(SendAfterSelfTickLoop, code, file: "lib/my_app/retry.ex")
    end

    test "ignores send_after to a different message than the handle_info clause" do
      code = ~S"""
      defmodule MyApp.Worker do
        use GenServer

        def handle_info(:tick, state) do
          Process.send_after(self(), :other_msg, 1_000)
          {:noreply, state}
        end
      end
      """

      assert_clean(SendAfterSelfTickLoop, code, file: "lib/my_app/worker.ex")
    end

    test "ignores non-GenServer modules" do
      code = ~S"""
      defmodule MyApp.Helper do
        def schedule, do: Process.send_after(self(), :tick, 1_000)
      end
      """

      assert_clean(SendAfterSelfTickLoop, code, file: "lib/my_app/helper.ex")
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.SweeperTest do
        use GenServer
        def handle_info(:tick, s) do
          Process.send_after(self(), :tick, 1_000)
          {:noreply, s}
        end
      end
      """

      assert_clean(SendAfterSelfTickLoop, code, file: "test/sweeper_test.exs")
    end
  end
end
