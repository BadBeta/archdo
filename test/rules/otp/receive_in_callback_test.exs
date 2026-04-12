defmodule Archdo.Rules.OTP.ReceiveInCallbackTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.ReceiveInCallback

  test "flags receive inside handle_call" do
    code = ~S"""
    defmodule MyApp.Server do
      use GenServer

      def handle_call(:fetch, _from, state) do
        send(some_pid(), :request)
        receive do
          {:response, data} -> {:reply, data, state}
        after
          5000 -> {:reply, :timeout, state}
        end
      end
    end
    """

    diags = assert_flagged(ReceiveInCallback, code)
    diag = hd(diags)
    assert diag.severity == :error
    assert diag.rule_id == "5.11"
    assert diag.title == "receive inside GenServer callback"
    assert diag.context.callback == :handle_call
  end

  test "flags receive inside handle_info" do
    code = ~S"""
    defmodule MyApp.Server do
      use GenServer

      def handle_info(:work, state) do
        receive do
          :done -> {:noreply, state}
        end
      end
    end
    """

    assert_flagged(ReceiveInCallback, code)
  end

  test "ignores non-GenServer modules" do
    code = ~S"""
    defmodule MyApp.Client do
      def fetch do
        send(server(), :request)
        receive do
          {:response, data} -> data
        end
      end
    end
    """

    assert_clean(ReceiveInCallback, code)
  end

  test "clean GenServer without receive" do
    code = ~S"""
    defmodule MyApp.Server do
      use GenServer

      def handle_call(:get, _from, state) do
        {:reply, state, state}
      end
    end
    """

    assert_clean(ReceiveInCallback, code)
  end
end
