defmodule Archdo.Rules.OTP.CustomRegistryTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.CustomRegistry

  test "flags GenServer named Registry that stores pids" do
    code = ~S"""
    defmodule MyApp.ServiceRegistry do
      use GenServer

      def handle_call({:register, name, pid}, _from, state) do
        {:reply, :ok, Map.put(state, name, pid)}
      end
    end
    """

    assert_flagged(CustomRegistry, code)
  end

  test "allows GenServer named Registry that uses built-in Registry" do
    code = ~S"""
    defmodule MyApp.ServiceRegistry do
      use GenServer

      def init(_) do
        Registry.start_link(keys: :unique, name: __MODULE__)
        {:ok, %{}}
      end

      def handle_call({:lookup, name, pid}, _from, state) do
        {:reply, Registry.lookup(__MODULE__, name), state}
      end
    end
    """

    assert_clean(CustomRegistry, code)
  end

  test "allows GenServer without Registry in name" do
    code = ~S"""
    defmodule MyApp.Worker do
      use GenServer

      def handle_call(:status, _from, state) do
        {:reply, :ok, state}
      end
    end
    """

    assert_clean(CustomRegistry, code)
  end
end
