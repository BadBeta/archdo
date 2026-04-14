defmodule Archdo.Rules.OTP.SilentCatchAllTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.SilentCatchAll

  test "flags silent catch-all handle_info" do
    code = ~S"""
    defmodule MyServer do
      use GenServer

      def handle_info(_msg, state) do
        {:noreply, state}
      end
    end
    """

    assert_flagged(SilentCatchAll, code)
  end

  test "allows catch-all with Logger" do
    code = ~S"""
    defmodule MyServer do
      use GenServer

      def handle_info(msg, state) do
        Logger.warning("Unexpected message: #{inspect(msg)}")
        {:noreply, state}
      end
    end
    """

    assert_clean(SilentCatchAll, code)
  end

  test "allows specific message pattern (not catch-all)" do
    code = ~S"""
    defmodule MyServer do
      use GenServer

      def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
        {:noreply, state}
      end
    end
    """

    assert_clean(SilentCatchAll, code)
  end

  test "ignores modules without GenServer callbacks" do
    code = ~S"""
    defmodule NotGenServer do
      def process(data) do
        {:ok, data}
      end
    end
    """

    assert_clean(SilentCatchAll, code)
  end
end
