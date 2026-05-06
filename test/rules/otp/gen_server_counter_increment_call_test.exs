defmodule Archdo.Rules.OTP.GenServerCounterIncrementCallTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.GenServerCounterIncrementCall

  describe "analyze/3" do
    test "flags handle_call returning state + 1 (bare integer counter)" do
      code = ~S"""
      defmodule MyApp.Counter do
        use GenServer

        def handle_call(:increment, _from, state) do
          {:reply, state + 1, state + 1}
        end
      end
      """

      diags =
        assert_flagged(GenServerCounterIncrementCall, code, file: "lib/my_app/counter.ex")

      assert hd(diags).rule_id == "5.69"
    end

    test "flags handle_call updating a single :count field" do
      code = ~S"""
      defmodule MyApp.Stats do
        use GenServer

        def handle_call(:hit, _from, state) do
          {:reply, :ok, %{state | count: state.count + 1}}
        end
      end
      """

      assert_flagged(GenServerCounterIncrementCall, code, file: "lib/my_app/stats.ex")
    end

    test "ignores handle_call doing real domain work" do
      code = ~S"""
      defmodule MyApp.Worker do
        use GenServer

        def handle_call({:fetch, id}, _from, state) do
          result = MyApp.Repo.get(MyApp.User, id)
          {:reply, result, state}
        end
      end
      """

      assert_clean(GenServerCounterIncrementCall, code, file: "lib/my_app/worker.ex")
    end

    test "ignores non-GenServer modules (no handle_call / use GenServer)" do
      code = ~S"""
      defmodule MyApp.Helper do
        def increment(state), do: state + 1
      end
      """

      assert_clean(GenServerCounterIncrementCall, code, file: "lib/my_app/helper.ex")
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.CounterTest do
        use GenServer
        def handle_call(:incr, _from, s), do: {:reply, s + 1, s + 1}
      end
      """

      assert_clean(GenServerCounterIncrementCall, code, file: "test/counter_test.exs")
    end
  end
end
