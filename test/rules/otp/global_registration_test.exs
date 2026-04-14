defmodule Archdo.Rules.OTP.GlobalRegistrationTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.GlobalRegistration

  test "flags :global.register_name usage" do
    code = ~S"""
    defmodule MyServer do
      def register(pid, name) do
        :global.register_name(name, pid)
      end
    end
    """

    assert_flagged(GlobalRegistration, code)
  end

  test "flags :global.register_name in start_link" do
    code = ~S"""
    defmodule MyServer do
      def start_link(opts) do
        {:ok, pid} = GenServer.start_link(__MODULE__, opts)
        :global.register_name(:my_server, pid)
        {:ok, pid}
      end
    end
    """

    assert_flagged(GlobalRegistration, code)
  end

  test "allows local name registration" do
    code = ~S"""
    defmodule MyServer do
      use GenServer

      def start_link(opts) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end
    end
    """

    assert_clean(GlobalRegistration, code)
  end
end
