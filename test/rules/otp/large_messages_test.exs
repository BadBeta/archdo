defmodule Archdo.Rules.OTP.LargeMessagesTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.LargeMessages

  test "flags conn sent via GenServer.cast" do
    code = ~S"""
    defmodule MyController do
      def create(conn, params) do
        GenServer.cast(MyWorker, {:process, conn, params})
        send_resp(conn, 202, "accepted")
      end
    end
    """

    assert_flagged(LargeMessages, code)
  end

  test "flags conn captured in Task.async" do
    code = ~S"""
    defmodule MyController do
      def create(conn, params) do
        Task.async(fn -> log_request(conn) end)
        send_resp(conn, 200, "ok")
      end
    end
    """

    assert_flagged(LargeMessages, code)
  end

  test "flags conn sent via send/2" do
    code = ~S"""
    defmodule MyController do
      def create(conn, params) do
        send(self(), {:log, conn})
        send_resp(conn, 200, "ok")
      end
    end
    """

    assert_flagged(LargeMessages, code)
  end

  test "allows extracting fields before sending" do
    code = ~S"""
    defmodule MyController do
      def create(conn, params) do
        ip = conn.remote_ip
        path = conn.request_path
        Task.async(fn -> log_request(ip, path) end)
        send_resp(conn, 200, "ok")
      end
    end
    """

    assert_clean(LargeMessages, code)
  end
end
