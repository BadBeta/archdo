defmodule Archdo.Rules.OTP.SingletonBottleneckTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.SingletonBottleneck

  test "flags named GenServer with Map.get in callbacks" do
    code = ~S"""
    defmodule MyApp.UserCache do
      use GenServer

      def start_link(opts) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end

      def handle_call({:get_user, id}, _from, state) do
        user = Map.get(state, id)
        {:reply, user, state}
      end
    end
    """

    assert_flagged(SingletonBottleneck, code)
  end

  test "allows GenServer without name registration" do
    code = ~S"""
    defmodule MyApp.Worker do
      use GenServer

      def start_link(opts) do
        GenServer.start_link(__MODULE__, opts)
      end

      def handle_call({:get, id}, _from, state) do
        {:reply, Map.get(state, id), state}
      end
    end
    """

    assert_clean(SingletonBottleneck, code)
  end

  test "allows named GenServer without Map lookups" do
    code = ~S"""
    defmodule MyApp.Counter do
      use GenServer

      def start_link(opts) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end

      def handle_call(:count, _from, state) do
        {:reply, state, state + 1}
      end
    end
    """

    assert_clean(SingletonBottleneck, code)
  end
end
