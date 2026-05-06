defmodule Archdo.Rules.OTP.GenTcpActiveTrueTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.GenTcpActiveTrue

  describe "analyze/3" do
    test "flags :gen_tcp.listen with active: true" do
      code = ~S"""
      defmodule MyApp.Server do
        def listen(port) do
          :gen_tcp.listen(port, [:binary, active: true])
        end
      end
      """

      diags = assert_flagged(GenTcpActiveTrue, code, file: "lib/my_app/server.ex")
      assert hd(diags).rule_id == "5.72"
    end

    test "flags :gen_tcp.connect with active: true" do
      code = ~S"""
      defmodule MyApp.Client do
        def connect(host, port) do
          :gen_tcp.connect(host, port, [:binary, active: true], 5_000)
        end
      end
      """

      assert_flagged(GenTcpActiveTrue, code, file: "lib/my_app/client.ex")
    end

    test "flags :gen_udp.open with active: true" do
      code = ~S"""
      defmodule MyApp.Udp do
        def open(port) do
          :gen_udp.open(port, [:binary, active: true])
        end
      end
      """

      assert_flagged(GenTcpActiveTrue, code, file: "lib/my_app/udp.ex")
    end

    test "ignores active: :once / active: N" do
      code = ~S"""
      defmodule MyApp.Server do
        def listen(port) do
          :gen_tcp.listen(port, [:binary, active: :once])
        end

        def batched(port) do
          :gen_tcp.listen(port, [:binary, active: 100])
        end
      end
      """

      assert_clean(GenTcpActiveTrue, code, file: "lib/my_app/server.ex")
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.ServerTest do
        def listen(port), do: :gen_tcp.listen(port, [:binary, active: true])
      end
      """

      assert_clean(GenTcpActiveTrue, code, file: "test/server_test.exs")
    end
  end
end
