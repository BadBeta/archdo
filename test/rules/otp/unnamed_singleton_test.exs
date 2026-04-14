defmodule Archdo.Rules.OTP.UnnamedSingletonTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.UnnamedSingleton

  test "flags GenServer using __MODULE__ in call without name registration" do
    code = ~S"""
    defmodule MyApp.Counter do
      use GenServer

      def increment do
        GenServer.call(__MODULE__, :increment)
      end

      def start_link(opts) do
        GenServer.start_link(__MODULE__, opts)
      end

      def handle_call(:increment, _from, state) do
        {:reply, state + 1, state + 1}
      end
    end
    """

    assert_flagged(UnnamedSingleton, code)
  end

  test "allows GenServer with name: __MODULE__" do
    code = ~S"""
    defmodule MyApp.Counter do
      use GenServer

      def increment do
        GenServer.call(__MODULE__, :increment)
      end

      def start_link(opts) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end

      def handle_call(:increment, _from, state) do
        {:reply, state + 1, state + 1}
      end
    end
    """

    assert_clean(UnnamedSingleton, code)
  end
end
