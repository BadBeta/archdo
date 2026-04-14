defmodule Archdo.Rules.OTP.SyncCallChainsTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.SyncCallChains

  test "flags GenServer.call inside a callback" do
    code = ~S"""
    defmodule MyApp.Coordinator do
      use GenServer

      def handle_call(:process, _from, state) do
        result = GenServer.call(MyApp.DataStore, :get_data)
        {:reply, result, state}
      end
    end
    """

    assert_flagged(SyncCallChains, code)
  end

  test "allows callbacks without GenServer.call" do
    code = ~S"""
    defmodule MyApp.Worker do
      use GenServer

      def handle_call(:status, _from, state) do
        {:reply, :ok, state}
      end
    end
    """

    assert_clean(SyncCallChains, code)
  end
end
