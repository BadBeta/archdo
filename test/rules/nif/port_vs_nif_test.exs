defmodule Archdo.Rules.NIF.PortVsNifTest do
  use Archdo.RuleCase

  alias Archdo.Rules.NIF.PortVsNif

  test "flags NIF doing I/O" do
    code = ~S"""
    defmodule MyApp.NetworkNif do
      use Rustler, otp_app: :my_app

      def send_packet(_data), do: :erlang.nif_error(:not_loaded)
      def recv_packet(), do: :erlang.nif_error(:not_loaded)
    end
    """

    diags = assert_flagged(PortVsNif, code)
    diag = hd(diags)
    assert diag.rule_id == "11.4"
    assert diag.title == "I/O-performing NIF — consider a Port"
  end

  test "allows pure computation NIF" do
    code = ~S"""
    defmodule MyApp.MathNif do
      use Rustler, otp_app: :my_app

      def multiply(_a, _b), do: :erlang.nif_error(:not_loaded)
      def hash(_data), do: :erlang.nif_error(:not_loaded)
    end
    """

    assert_clean(PortVsNif, code)
  end
end
