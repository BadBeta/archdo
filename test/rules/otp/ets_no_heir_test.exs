defmodule Archdo.Rules.OTP.EtsNoHeirTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.EtsNoHeir

  test "flags ETS table in GenServer without heir" do
    code = ~S"""
    defmodule MyApp.Cache do
      use GenServer

      def init(_) do
        table = :ets.new(:cache, [:set, :public])
        {:ok, %{table: table}}
      end
    end
    """

    assert_flagged(EtsNoHeir, code)
  end

  test "allows ETS table with heir configured" do
    code = ~S"""
    defmodule MyApp.Cache do
      use GenServer

      def init(supervisor_pid) do
        table = :ets.new(:cache, [:set, :public, {:heir, supervisor_pid, nil}])
        {:ok, %{table: table}}
      end
    end
    """

    assert_clean(EtsNoHeir, code)
  end

  test "ignores ETS tables in non-GenServer modules" do
    code = ~S"""
    defmodule MyApp.Utils do
      def create_table do
        :ets.new(:temp, [:set])
      end
    end
    """

    assert_clean(EtsNoHeir, code)
  end
end
