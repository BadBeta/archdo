defmodule Archdo.Rules.OTP.ApplicationGetEnvInCallbackTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.ApplicationGetEnvInCallback

  describe "analyze/3" do
    test "flags Application.get_env in handle_call" do
      code = ~S"""
      defmodule MyApp.Resolver do
        use GenServer

        def handle_call({:resolve, key}, _from, state) do
          backend = Application.get_env(:my_app, :backend)
          {:reply, backend.lookup(key), state}
        end
      end
      """

      diags =
        assert_flagged(ApplicationGetEnvInCallback, code, file: "lib/my_app/resolver.ex")

      assert hd(diags).rule_id == "5.71"
    end

    test "flags Application.fetch_env! in handle_info" do
      code = ~S"""
      defmodule MyApp.Worker do
        use GenServer

        def handle_info(:tick, state) do
          interval = Application.fetch_env!(:my_app, :interval_ms)
          schedule(interval)
          {:noreply, state}
        end
      end
      """

      assert_flagged(ApplicationGetEnvInCallback, code, file: "lib/my_app/worker.ex")
    end

    test "ignores Application.get_env outside callbacks (e.g., in init)" do
      code = ~S"""
      defmodule MyApp.Resolver do
        use GenServer

        def init(_) do
          backend = Application.get_env(:my_app, :backend)
          {:ok, %{backend: backend}}
        end
      end
      """

      assert_clean(ApplicationGetEnvInCallback, code, file: "lib/my_app/resolver.ex")
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.WorkerTest do
        use GenServer

        def handle_call(_, _, s) do
          v = Application.get_env(:my_app, :v)
          {:reply, v, s}
        end
      end
      """

      assert_clean(ApplicationGetEnvInCallback, code, file: "test/worker_test.exs")
    end
  end
end
