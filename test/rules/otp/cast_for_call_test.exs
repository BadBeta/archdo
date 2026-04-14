defmodule Archdo.Rules.OTP.CastForCallTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.CastForCall

  test "flags handle_cast with Repo operations" do
    code = ~S"""
    defmodule MyServer do
      use GenServer

      def handle_cast({:save, data}, state) do
        Repo.insert!(data)
        {:noreply, state}
      end
    end
    """

    assert_flagged(CastForCall, code)
  end

  test "flags handle_cast with result-suggesting tuple message" do
    code = ~S"""
    defmodule MyServer do
      use GenServer

      def handle_cast({:create, data, user}, state) do
        {:noreply, Map.put(state, :data, data)}
      end
    end
    """

    assert_flagged(CastForCall, code)
  end

  test "allows handle_cast for fire-and-forget operations" do
    code = ~S"""
    defmodule MyServer do
      use GenServer

      def handle_cast({:log, msg}, state) do
        Logger.info(msg)
        {:noreply, state}
      end
    end
    """

    assert_clean(CastForCall, code)
  end

  test "allows handle_call with Repo operations" do
    code = ~S"""
    defmodule MyServer do
      use GenServer

      def handle_call({:create, data}, _from, state) do
        case Repo.insert(data) do
          {:ok, record} -> {:reply, {:ok, record}, state}
          {:error, cs} -> {:reply, {:error, cs}, state}
        end
      end
    end
    """

    assert_clean(CastForCall, code)
  end

  test "ignores non-GenServer modules" do
    code = ~S"""
    defmodule NotAGenServer do
      def process(data) do
        Repo.insert!(data)
      end
    end
    """

    assert_clean(CastForCall, code)
  end
end
