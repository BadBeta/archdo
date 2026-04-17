defmodule Archdo.Rules.OTP.MoreOTPTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.{LargeMessages, SingletonBottleneck, SyncCallChains, UnboundedState}

  describe "5.18 SyncCallChains" do
    test "flags GenServer.call inside handle_call" do
      code = ~S"""
      defmodule MyApp.ServiceA do
        use GenServer
        def handle_call(:fetch, _from, state) do
          data = GenServer.call(MyApp.ServiceB, :get_data)
          {:reply, data, state}
        end
      end
      """

      diags = assert_flagged(SyncCallChains, code)
      diag = hd(diags)
      assert diag.rule_id == "5.18"
      assert diag.title == "Synchronous GenServer call inside a callback"
      assert diag.context.target == "MyApp.ServiceB"
    end

    test "allows GenServer.call outside callbacks" do
      code = ~S"""
      defmodule MyApp.Client do
        use GenServer
        def get_data do
          GenServer.call(MyApp.ServiceB, :get_data)
        end
        def handle_call(:local, _from, state), do: {:reply, :ok, state}
      end
      """

      assert_clean(SyncCallChains, code)
    end
  end

  describe "5.19 LargeMessages" do
    test "flags conn passed to spawn" do
      code = ~S"""
      defmodule MyAppWeb.LogController do
        def index(conn, _params) do
          spawn(fn -> log_request(conn) end)
          send_resp(conn, 200, "ok")
        end
      end
      """

      diags = assert_flagged(LargeMessages, code)
      diag = hd(diags)
      assert diag.rule_id == "5.19"
      assert diag.title == "conn sent to another process"
      assert diag.context.kind == :conn
    end
  end

  describe "5.31 UnboundedState" do
    test "flags GenServer accumulating without cleanup" do
      code = ~S"""
      defmodule MyApp.Cache do
        use GenServer
        def init(_), do: {:ok, %{data: %{}}}
        def handle_cast({:put, key, val}, state) do
          {:noreply, %{state | data: Map.put(state.data, key, val)}}
        end
      end
      """

      diags = assert_flagged(UnboundedState, code)
      diag = hd(diags)
      assert diag.rule_id == "5.31"
      assert diag.title == "Unbounded GenServer state"
      assert diag.context.kind == :map_accumulation
    end

    test "allows GenServer with cleanup" do
      code = ~S"""
      defmodule MyApp.Cache do
        use GenServer
        def init(_), do: {:ok, %{data: %{}}}
        def handle_cast({:put, key, val}, state) do
          {:noreply, %{state | data: Map.put(state.data, key, val)}}
        end
        def handle_info(:prune, state) do
          {:noreply, %{state | data: Map.take(state.data, recent_keys())}}
        end
      end
      """

      assert_clean(UnboundedState, code)
    end
  end
end
