defmodule Archdo.Rules.OTP.TaskAsyncWithoutAwaitTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.TaskAsyncWithoutAwait

  test "flags Task.async without await" do
    code = ~S"""
    defmodule MyApp.Worker do
      def fire_and_forget(data) do
        Task.async(fn -> process(data) end)
        :ok
      end
    end
    """

    diags = assert_flagged(TaskAsyncWithoutAwait, code)
    diag = hd(diags)
    assert diag.severity == :warning
    assert diag.rule_id == "5.22"
    assert diag.title == "Task.async without Task.await"
  end

  test "allows Task.async with Task.await" do
    code = ~S"""
    defmodule MyApp.Worker do
      def compute(data) do
        task = Task.async(fn -> expensive(data) end)
        Task.await(task)
      end
    end
    """

    assert_clean(TaskAsyncWithoutAwait, code)
  end

  test "allows Task.async with Task.yield" do
    code = ~S"""
    defmodule MyApp.Worker do
      def compute(data) do
        task = Task.async(fn -> expensive(data) end)
        Task.yield(task, 5000)
      end
    end
    """

    assert_clean(TaskAsyncWithoutAwait, code)
  end
end
