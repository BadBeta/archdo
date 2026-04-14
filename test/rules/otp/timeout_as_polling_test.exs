defmodule Archdo.Rules.OTP.TimeoutAsPollingTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.TimeoutAsPolling

  test "flags handle_info :timeout that returns another timeout" do
    code = ~S"""
    defmodule MyApp.Poller do
      use GenServer

      def handle_info(:timeout, state) do
        do_poll()
        {:noreply, state, 5000}
      end
    end
    """

    assert_flagged(TimeoutAsPolling, code)
  end

  test "allows handle_info :timeout without re-scheduling" do
    code = ~S"""
    defmodule MyApp.IdleHandler do
      use GenServer

      def handle_info(:timeout, state) do
        cleanup(state)
        {:noreply, %{}}
      end
    end
    """

    assert_clean(TimeoutAsPolling, code)
  end

  test "allows :timer.send_interval pattern" do
    code = ~S"""
    defmodule MyApp.Poller do
      use GenServer

      def init(_) do
        :timer.send_interval(5000, :tick)
        {:ok, %{}}
      end

      def handle_info(:tick, state) do
        do_poll()
        {:noreply, state}
      end
    end
    """

    assert_clean(TimeoutAsPolling, code)
  end
end
