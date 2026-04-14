defmodule Archdo.Rules.OTP.UnboundedStateTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.UnboundedState

  test "flags Map.put in callback without cleanup" do
    code = ~S"""
    defmodule MyApp.Cache do
      use GenServer

      def handle_cast({:put, key, value}, state) do
        {:noreply, Map.put(state, key, value)}
      end
    end
    """

    assert_flagged(UnboundedState, code)
  end

  test "allows Map.put with Map.delete cleanup" do
    code = ~S"""
    defmodule MyApp.Cache do
      use GenServer

      def handle_cast({:put, key, value}, state) do
        {:noreply, Map.put(state, key, value)}
      end

      def handle_cast({:evict, key}, state) do
        {:noreply, Map.delete(state, key)}
      end
    end
    """

    assert_clean(UnboundedState, code)
  end

  test "flags list prepend without pruning" do
    code = ~S"""
    defmodule MyApp.EventLog do
      use GenServer

      def handle_cast({:log, event}, state) do
        {:noreply, [event | state]}
      end
    end
    """

    assert_flagged(UnboundedState, code)
  end

  test "ignores non-GenServer modules" do
    code = ~S"""
    defmodule MyApp.Utils do
      def add_to_map(map, key, value) do
        Map.put(map, key, value)
      end
    end
    """

    assert_clean(UnboundedState, code)
  end
end
