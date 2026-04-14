defmodule Archdo.Rules.OTP.UnnecessaryProcessTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.UnnecessaryProcess

  test "flags GenServer with no init and no mutations" do
    code = ~S"""
    defmodule MyApp.Calculator do
      use GenServer

      def handle_call({:add, a, b}, _from, state) do
        {:reply, a + b, state}
      end
    end
    """

    assert_flagged(UnnecessaryProcess, code)
  end

  test "flags GenServer with trivial {:ok, %{}} init and no mutations" do
    code = ~S"""
    defmodule MyApp.Calculator do
      use GenServer

      def init(_) do
        {:ok, %{}}
      end

      def handle_call({:add, a, b}, _from, state) do
        {:reply, a + b, state}
      end
    end
    """

    assert_flagged(UnnecessaryProcess, code)
  end

  test "allows GenServer with state mutations" do
    code = ~S"""
    defmodule MyApp.Counter do
      use GenServer

      def init(_) do
        {:ok, %{count: 0}}
      end

      def handle_call(:increment, _from, state) do
        new_state = %{state | count: state.count + 1}
        {:reply, new_state.count, new_state}
      end
    end
    """

    assert_clean(UnnecessaryProcess, code)
  end

  test "allows LiveView modules" do
    code = ~S"""
    defmodule MyAppWeb.PageLive do
      use Phoenix.LiveView

      def init(_) do
        {:ok, %{}}
      end

      def handle_call(:check, _from, state) do
        {:reply, :ok, state}
      end
    end
    """

    assert_clean(UnnecessaryProcess, code)
  end
end
