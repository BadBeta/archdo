defmodule Archdo.Rules.OTP.MissingImplOnKnownCallbackTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.MissingImplOnKnownCallback

  test "fires on GenServer module with `def init(_)` missing `@impl true`" do
    code = ~S"""
    defmodule MyApp.Worker do
      use GenServer

      def init(state) do
        {:ok, state}
      end

      def handle_call(:get, _from, state), do: {:reply, state, state}
    end
    """

    diags = assert_flagged(MissingImplOnKnownCallback, code)
    assert hd(diags).rule_id == "5.61"
    assert hd(diags).severity == :warning
    assert hd(diags).message =~ "@impl"
  end

  test "does NOT fire when @impl true precedes the callback" do
    code = ~S"""
    defmodule MyApp.Worker do
      use GenServer

      @impl true
      def init(state), do: {:ok, state}

      @impl true
      def handle_call(:get, _from, state), do: {:reply, state, state}
    end
    """

    assert_clean(MissingImplOnKnownCallback, code)
  end

  test "does NOT fire on a non-callback function inside a GenServer module" do
    code = ~S"""
    defmodule MyApp.Worker do
      use GenServer

      @impl true
      def init(state), do: {:ok, state}

      def helper(x), do: x + 1
    end
    """

    assert_clean(MissingImplOnKnownCallback, code)
  end
end
