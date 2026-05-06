defmodule Archdo.Rules.OTP.GenServerCallNoExitCatchTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.GenServerCallNoExitCatch

  test "fires on `GenServer.call(name, msg)` to a registered name without try/catch :exit" do
    code = ~S"""
    defmodule MyApp.Client do
      def status do
        GenServer.call(MyApp.Worker, :status)
      end
    end
    """

    diags = assert_flagged(GenServerCallNoExitCatch, code)
    assert hd(diags).rule_id == "5.60"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ ":exit"
  end

  test "does NOT fire when GenServer.call is wrapped in try/catch :exit" do
    code = ~S"""
    defmodule MyApp.Client do
      def status do
        try do
          {:ok, GenServer.call(MyApp.Worker, :status)}
        catch
          :exit, _ -> {:error, :down}
        end
      end
    end
    """

    assert_clean(GenServerCallNoExitCatch, code)
  end

  test "does NOT fire on GenServer.call to a pid (caller already has the pid; supervision provides liveness)" do
    code = ~S"""
    defmodule MyApp.Client do
      def status(pid) when is_pid(pid) do
        GenServer.call(pid, :status)
      end
    end
    """

    assert_clean(GenServerCallNoExitCatch, code)
  end
end
