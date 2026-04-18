defmodule Archdo.Rules.Module.MissingRescueAtBoundaryTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.MissingRescueAtBoundary

  describe "analyze/3" do
    test "flags GenServer.call to variable PID without catch :exit" do
      code = ~S"""
      defmodule MyApp.Client do
        def get_status(pid) do
          GenServer.call(pid, :status)
        end
      end
      """

      diags = assert_flagged(MissingRescueAtBoundary, code)
      assert hd(diags).rule_id == "6.16"
      assert hd(diags).message =~ "GenServer.call"
    end

    test "allows GenServer.call to __MODULE__" do
      code = ~S"""
      defmodule MyApp.Server do
        use GenServer

        def get_status do
          GenServer.call(__MODULE__, :status)
        end
      end
      """

      assert_clean(MissingRescueAtBoundary, code)
    end

    test "allows GenServer.call with catch :exit" do
      code = ~S"""
      defmodule MyApp.Client do
        def get_status(pid) do
          try do
            GenServer.call(pid, :status)
          catch
            :exit, _ -> {:error, :down}
          end
        end
      end
      """

      assert_clean(MissingRescueAtBoundary, code)
    end

    test "flags :erlang.binary_to_term without rescue" do
      code = ~S"""
      defmodule MyApp.Protocol do
        def decode(data) do
          term = :erlang.binary_to_term(data, [:safe])
          {:ok, term}
        end
      end
      """

      diags = assert_flagged(MissingRescueAtBoundary, code)
      assert hd(diags).rule_id == "6.16"
      assert hd(diags).message =~ "binary_to_term"
    end

    test "allows :erlang.binary_to_term with rescue" do
      code = ~S"""
      defmodule MyApp.Protocol do
        def decode(data) do
          try do
            {:ok, :erlang.binary_to_term(data, [:safe])}
          rescue
            ArgumentError -> {:error, :malformed}
          end
        end
      end
      """

      assert_clean(MissingRescueAtBoundary, code)
    end
  end
end
