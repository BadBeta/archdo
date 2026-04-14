defmodule Archdo.Rules.OTP.UnsupervisedTaskTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.UnsupervisedTask

  test "flags Task.start in production code" do
    code = ~S"""
    defmodule MyApp.Notifier do
      def notify(user) do
        Task.start(fn -> send_email(user) end)
      end
    end
    """

    assert_flagged(UnsupervisedTask, code)
  end

  test "flags Task.start_link in production code" do
    code = ~S"""
    defmodule MyApp.Notifier do
      def notify(user) do
        Task.start_link(fn -> send_email(user) end)
      end
    end
    """

    assert_flagged(UnsupervisedTask, code)
  end

  test "allows Task.Supervisor usage" do
    code = ~S"""
    defmodule MyApp.Notifier do
      def notify(user) do
        Task.Supervisor.start_child(MyApp.TaskSupervisor, fn -> send_email(user) end)
      end
    end
    """

    assert_clean(UnsupervisedTask, code)
  end

  test "ignores test files" do
    code = ~S"""
    defmodule MyApp.NotifierTest do
      def test_it do
        Task.start(fn -> :ok end)
      end
    end
    """

    assert_clean(UnsupervisedTask, code, file: "test/notifier_test.exs")
  end
end
