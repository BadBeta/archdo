defmodule Archdo.Rules.OTP.ProcessSleepTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.ProcessSleep

  test "flags Process.sleep in production code" do
    code = ~S"""
    defmodule MyApp.Worker do
      def retry(attempt) do
        Process.sleep(1000)
        do_work()
      end
    end
    """

    diags = assert_flagged(ProcessSleep, code)
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "Process.sleep"
  end

  test "flags :timer.sleep in production code" do
    code = ~S"""
    defmodule MyApp.Worker do
      def wait do
        :timer.sleep(5000)
      end
    end
    """

    diags = assert_flagged(ProcessSleep, code)
    assert hd(diags).message =~ ":timer.sleep"
  end

  test "ignores Mix tasks (operational layer)" do
    code = ~S"""
    defmodule Mix.Tasks.MyApp.Backfill do
      use Mix.Task
      def run(_) do
        Process.sleep(500)
        :ok
      end
    end
    """

    assert_clean(ProcessSleep, code, file: "lib/mix/tasks/my_app.backfill.ex")
  end

  test "ignores release.ex (operational layer)" do
    code = ~S"""
    defmodule MyApp.Release do
      def migrate do
        :timer.sleep(1000)
      end
    end
    """

    assert_clean(ProcessSleep, code, file: "lib/my_app/release.ex")
  end

  test "ignores test files" do
    code = ~S"""
    defmodule MyApp.WorkerTest do
      def wait do
        Process.sleep(100)
      end
    end
    """

    assert_clean(ProcessSleep, code, file: "test/worker_test.exs")
  end
end
