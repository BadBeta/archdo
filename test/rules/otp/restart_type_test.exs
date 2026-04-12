defmodule Archdo.Rules.OTP.RestartTypeMismatchTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.RestartTypeMismatch

  test "flags Task module marked as :permanent" do
    code = ~S"""
    defmodule MyApp.OneShotTask do
      use Task

      def child_spec(args) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :run, [args]},
          restart: :permanent
        }
      end

      def run(_args), do: :ok
    end
    """

    diags = assert_flagged(RestartTypeMismatch, code)
    assert hd(diags).message =~ "Task-like"
    assert hd(diags).message =~ ":permanent"
  end

  test "allows GenServer with :permanent" do
    code = ~S"""
    defmodule MyApp.Server do
      use GenServer

      def child_spec(args) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [args]},
          restart: :permanent
        }
      end
    end
    """

    assert_clean(RestartTypeMismatch, code)
  end

  test "flags GenServer marked as :temporary" do
    code = ~S"""
    defmodule MyApp.LongRunning do
      use GenServer

      def child_spec(args) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [args]},
          restart: :temporary
        }
      end
    end
    """

    diags = assert_flagged(RestartTypeMismatch, code)
    assert hd(diags).message =~ "GenServer"
    assert hd(diags).message =~ ":temporary"
  end
end
