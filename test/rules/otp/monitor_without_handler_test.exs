defmodule Archdo.Rules.OTP.MonitorWithoutHandlerTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.MonitorWithoutHandler

  test "flags Process.monitor without DOWN handler" do
    code = ~S"""
    defmodule MyApp.Watcher do
      use GenServer
      def init(pid) do
        Process.monitor(pid)
        {:ok, %{}}
      end
      def handle_info(_msg, state), do: {:noreply, state}
    end
    """

    diags = assert_flagged(MonitorWithoutHandler, code)
    diag = hd(diags)
    assert diag.rule_id == "5.20"
    assert diag.title == "Process.monitor without :DOWN handler"
    assert diag.context.kind == :monitor
  end

  test "ignores non-GenServer modules" do
    code = ~S"""
    defmodule MyApp.Util do
      def watch(pid), do: Process.monitor(pid)
    end
    """

    assert_clean(MonitorWithoutHandler, code)
  end
end
