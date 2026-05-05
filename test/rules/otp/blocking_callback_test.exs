defmodule Archdo.Rules.OTP.BlockingCallbackTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.BlockingCallback

  test "flags HTTP call in handle_call" do
    code = ~S"""
    defmodule MyApp.Server do
      use GenServer
      def handle_call(:fetch, _from, state) do
        result = Req.get!("https://api.example.com")
        {:reply, result, state}
      end
    end
    """

    diags = assert_flagged(BlockingCallback, code)
    assert hd(diags).severity == :warning
    assert hd(diags).message =~ "handle_call"
    assert hd(diags).message =~ "Req.get!"
  end

  test "flags Process.sleep in handle_info" do
    code = ~S"""
    defmodule MyApp.Server do
      use GenServer
      def handle_info(:poll, state) do
        Process.sleep(5000)
        {:noreply, state}
      end
    end
    """

    assert_flagged(BlockingCallback, code)
  end

  test "allows clean callbacks" do
    code = ~S"""
    defmodule MyApp.Server do
      use GenServer
      def handle_call(:get, _from, state) do
        {:reply, state.value, state}
      end
    end
    """

    assert_clean(BlockingCallback, code)
  end

  test "ignores non-GenServer modules" do
    code = ~S"""
    defmodule MyApp.Worker do
      def fetch do
        Req.get!("https://api.example.com")
      end
    end
    """

    assert_clean(BlockingCallback, code)
  end

  describe "Plug call/2 — M17 extension" do
    test "fires on plug calling Process.sleep in call/2" do
      code = ~S"""
      defmodule MyAppWeb.SlowPlug do
        @behaviour Plug

        def init(opts), do: opts

        def call(conn, _opts) do
          Process.sleep(100)
          conn
        end
      end
      """

      diags = assert_flagged(BlockingCallback, code, file: "lib/my_app_web/plugs/slow_plug.ex")
      assert hd(diags).rule_id == "5.9"
      assert hd(diags).severity == :warning
      assert hd(diags).message =~ "Process.sleep"
    end

    test "does NOT fire on plug calling Req.get with no timeout (covered by CE-34, not 5.9)" do
      # CE-34 (VolatileCallNoTimeout) owns timeout-less HTTP detection.
      # 5.9 stays out of that lane to avoid double-flagging.
      code = ~S"""
      defmodule MyAppWeb.FetchPlug do
        @behaviour Plug

        def init(opts), do: opts

        def call(conn, _opts) do
          {:ok, _} = Req.get("https://api.example.com/data")
          conn
        end
      end
      """

      assert_clean(BlockingCallback, code, file: "lib/my_app_web/plugs/fetch_plug.ex")
    end

    test "does NOT fire on a plug doing only conn manipulation" do
      code = ~S"""
      defmodule MyAppWeb.HeaderPlug do
        @behaviour Plug

        def init(opts), do: opts

        def call(conn, _opts) do
          Plug.Conn.put_resp_header(conn, "x-custom", "value")
        end
      end
      """

      assert_clean(BlockingCallback, code, file: "lib/my_app_web/plugs/header_plug.ex")
    end
  end
end
