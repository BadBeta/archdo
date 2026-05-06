defmodule Archdo.Rules.OTP.GenTcpRecvNoTimeoutTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.GenTcpRecvNoTimeout

  describe "analyze/3" do
    test "flags :gen_tcp.recv/2 (no timeout)" do
      code = ~S"""
      defmodule MyApp.Client do
        def read(sock) do
          :gen_tcp.recv(sock, 0)
        end
      end
      """

      diags = assert_flagged(GenTcpRecvNoTimeout, code, file: "lib/my_app/client.ex")
      assert hd(diags).rule_id == "5.73"
    end

    test "flags :gen_tcp.connect/3 (no timeout)" do
      code = ~S"""
      defmodule MyApp.Client do
        def connect(host, port) do
          :gen_tcp.connect(host, port, [:binary, active: false])
        end
      end
      """

      assert_flagged(GenTcpRecvNoTimeout, code, file: "lib/my_app/client.ex")
    end

    test "ignores :gen_tcp.recv/3 (with timeout)" do
      code = ~S"""
      defmodule MyApp.Client do
        def read(sock) do
          :gen_tcp.recv(sock, 0, 30_000)
        end
      end
      """

      assert_clean(GenTcpRecvNoTimeout, code, file: "lib/my_app/client.ex")
    end

    test "ignores :gen_tcp.connect/4 (with timeout)" do
      code = ~S"""
      defmodule MyApp.Client do
        def connect(host, port) do
          :gen_tcp.connect(host, port, [:binary], 5_000)
        end
      end
      """

      assert_clean(GenTcpRecvNoTimeout, code, file: "lib/my_app/client.ex")
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.ClientTest do
        def read(sock), do: :gen_tcp.recv(sock, 0)
      end
      """

      assert_clean(GenTcpRecvNoTimeout, code, file: "test/client_test.exs")
    end
  end
end
