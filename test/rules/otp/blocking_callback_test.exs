defmodule Archdo.Rules.OTP.BlockingCallbackTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.BlockingCallback

  test "flags HTTP call in handle_call" do
    code = ~S"""
    defmodule MyApp.Server do
      use GenServer
      def handle_call(:fetch, _from, state) do
        result = Req.get!("https://api.example.com")
        {:reply, result, state}
      end
    end
    """

    diags = assert_flagged(BlockingCallback, code)
    assert hd(diags).severity == :warning
    assert hd(diags).message =~ "handle_call"
    assert hd(diags).message =~ "Req.get!"
  end

  test "flags Process.sleep in handle_info" do
    code = ~S"""
    defmodule MyApp.Server do
      use GenServer
      def handle_info(:poll, state) do
        Process.sleep(5000)
        {:noreply, state}
      end
    end
    """

    assert_flagged(BlockingCallback, code)
  end

  test "allows clean callbacks" do
    code = ~S"""
    defmodule MyApp.Server do
      use GenServer
      def handle_call(:get, _from, state) do
        {:reply, state.value, state}
      end
    end
    """

    assert_clean(BlockingCallback, code)
  end

  test "ignores non-GenServer modules" do
    code = ~S"""
    defmodule MyApp.Worker do
      def fetch do
        Req.get!("https://api.example.com")
      end
    end
    """

    assert_clean(BlockingCallback, code)
  end
end
