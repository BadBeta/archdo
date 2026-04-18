defmodule Archdo.Rules.OTP.StalePidReferenceTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.StalePidReference

  describe "analyze/3" do
    test "flags PID stored in ETS without monitor" do
      code = ~S"""
      defmodule MyApp.Tracker do
        use GenServer

        def handle_cast({:register, pid}, state) do
          :ets.insert(state.table, {:worker, pid})
          {:noreply, state}
        end
      end
      """

      diags = assert_flagged(StalePidReference, code)
      assert hd(diags).rule_id == "5.36"
    end

    test "allows PID in ETS with Process.monitor" do
      code = ~S"""
      defmodule MyApp.Tracker do
        use GenServer

        def handle_cast({:register, pid}, state) do
          ref = Process.monitor(pid)
          :ets.insert(state.table, {ref, pid})
          {:noreply, state}
        end
      end
      """

      assert_clean(StalePidReference, code)
    end

    test "flags PID stored in state map without monitor" do
      code = ~S"""
      defmodule MyApp.Manager do
        use GenServer

        def handle_call({:set_worker, worker_pid}, _from, state) do
          {:reply, :ok, %{state | worker_pid: worker_pid}}
        end
      end
      """

      diags = assert_flagged(StalePidReference, code)
      assert hd(diags).rule_id == "5.36"
    end

    test "allows PID in state with Process.monitor" do
      code = ~S"""
      defmodule MyApp.Manager do
        use GenServer

        def handle_call({:set_worker, worker_pid}, _from, state) do
          ref = Process.monitor(worker_pid)
          {:reply, :ok, %{state | worker_pid: worker_pid, worker_ref: ref}}
        end
      end
      """

      assert_clean(StalePidReference, code)
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.TrackerTest do
        def register(pid) do
          :ets.insert(:test_table, {:worker, pid})
        end
      end
      """

      assert_clean(StalePidReference, code, file: "test/tracker_test.exs")
    end
  end
end
