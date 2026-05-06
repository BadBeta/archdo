defmodule Archdo.Rules.OTP.TaskAsyncInGenServerTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.TaskAsyncInGenServer

  test "fires on `Task.async(fn -> ... end)` inside a GenServer module" do
    code = ~S"""
    defmodule MyApp.Worker do
      use GenServer

      @impl true
      def init(state), do: {:ok, state}

      @impl true
      def handle_call(:fetch, _from, state) do
        task = Task.async(fn -> ExternalService.fetch() end)
        {:reply, Task.await(task), state}
      end
    end
    """

    diags = assert_flagged(TaskAsyncInGenServer, code)
    assert hd(diags).rule_id == "5.65"
    assert hd(diags).severity == :warning
    assert hd(diags).message =~ "async_nolink"
  end

  test "does NOT fire on `Task.Supervisor.async_nolink(...)` inside a GenServer" do
    code = ~S"""
    defmodule MyApp.Worker do
      use GenServer

      @impl true
      def init(state), do: {:ok, state}

      @impl true
      def handle_call(:fetch, _from, state) do
        task = Task.Supervisor.async_nolink(MyApp.TaskSup, fn -> ExternalService.fetch() end)
        {:reply, Task.await(task), state}
      end
    end
    """

    assert_clean(TaskAsyncInGenServer, code)
  end

  test "does NOT fire on Task.async outside a GenServer module" do
    code = ~S"""
    defmodule MyApp.Plain do
      def go do
        task = Task.async(fn -> heavy_work() end)
        Task.await(task)
      end

      defp heavy_work, do: :ok
    end
    """

    assert_clean(TaskAsyncInGenServer, code)
  end
end
