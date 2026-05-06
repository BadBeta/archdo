defmodule Archdo.Rules.OTP.MissingTelemetryLiveViewMountTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.MissingTelemetryLiveViewMount

  test "fires on LiveView mount/3 with no telemetry or Logger" do
    code = ~S"""
    defmodule MyAppWeb.UserLive do
      use Phoenix.LiveView

      def mount(_params, _session, socket) do
        {:ok, assign(socket, :user, nil)}
      end
    end
    """

    diags =
      assert_flagged(MissingTelemetryLiveViewMount, code,
        file: "lib/my_app_web/live/user_live.ex"
      )

    assert hd(diags).rule_id == "5.58"
    assert hd(diags).severity == :info
  end

  test "does NOT fire when mount/3 calls :telemetry.execute" do
    code = ~S"""
    defmodule MyAppWeb.UserLive do
      use Phoenix.LiveView

      def mount(_params, _session, socket) do
        :telemetry.execute([:my_app, :user_live, :mount], %{}, %{})
        {:ok, assign(socket, :user, nil)}
      end
    end
    """

    assert_clean(MissingTelemetryLiveViewMount, code, file: "lib/my_app_web/live/user_live.ex")
  end

  test "does NOT fire on a non-LV module that defines mount/3" do
    code = ~S"""
    defmodule MyApp.Worker do
      def mount(a, b, c), do: {:ok, [a, b, c]}
    end
    """

    assert_clean(MissingTelemetryLiveViewMount, code, file: "lib/my_app/worker.ex")
  end
end
