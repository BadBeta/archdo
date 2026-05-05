defmodule Archdo.Rules.Boundary.MissingTelemetryAuthPlugTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Boundary.MissingTelemetryAuthPlug

  test "fires on an auth plug (file path) without telemetry or Logger" do
    code = ~S"""
    defmodule MyAppWeb.Plugs.AuthPlug do
      @behaviour Plug

      def init(opts), do: opts

      def call(conn, _opts) do
        case verify_token(conn) do
          {:ok, _} -> conn
          :error -> Plug.Conn.send_resp(conn, 401, "")
        end
      end

      defp verify_token(_conn), do: :error
    end
    """

    diags = assert_flagged(MissingTelemetryAuthPlug, code, file: "lib/my_app_web/plugs/auth_plug.ex")
    assert hd(diags).rule_id == "4.21"
    assert hd(diags).severity == :info
  end

  test "does NOT fire when auth plug emits :telemetry.execute" do
    code = ~S"""
    defmodule MyAppWeb.Plugs.AuthPlug do
      @behaviour Plug

      def init(opts), do: opts

      def call(conn, _opts) do
        :telemetry.execute([:my_app, :auth, :attempt], %{}, %{})
        conn
      end
    end
    """

    assert_clean(MissingTelemetryAuthPlug, code, file: "lib/my_app_web/plugs/auth_plug.ex")
  end

  test "does NOT fire on a non-auth plug (no auth keyword in name or body)" do
    code = ~S"""
    defmodule MyAppWeb.Plugs.HeaderPlug do
      @behaviour Plug

      def init(opts), do: opts
      def call(conn, _opts), do: conn
    end
    """

    assert_clean(MissingTelemetryAuthPlug, code, file: "lib/my_app_web/plugs/header_plug.ex")
  end
end
