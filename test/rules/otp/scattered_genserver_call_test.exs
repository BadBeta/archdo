defmodule Archdo.Rules.OTP.ScatteredGenserverCallTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.ScatteredGenserverCall

  test "flags GenServer.call to a different module" do
    code = ~S"""
    defmodule MyApp.Consumer do
      def fetch_data do
        GenServer.call(MyApp.DataServer, :get_data)
      end
    end
    """

    assert_flagged(ScatteredGenserverCall, code)
  end

  test "flags Agent.get to a different module" do
    code = ~S"""
    defmodule MyApp.Consumer do
      def get_state do
        Agent.get(MyApp.StateStore, & &1)
      end
    end
    """

    assert_flagged(ScatteredGenserverCall, code)
  end

  test "allows GenServer.call within the defining module" do
    code = ~S"""
    defmodule MyApp.DataServer do
      use GenServer

      def fetch_data do
        GenServer.call(MyApp.DataServer, :get_data)
      end
    end
    """

    assert_clean(ScatteredGenserverCall, code)
  end

  test "ignores test files" do
    code = ~S"""
    defmodule MyApp.DataServerTest do
      def test_it do
        GenServer.call(MyApp.DataServer, :get_data)
      end
    end
    """

    assert_clean(ScatteredGenserverCall, code, file: "test/data_server_test.exs")
  end
end
