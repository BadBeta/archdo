defmodule Archdo.Rules.CE.BoundaryTelemetryTest do
  use Archdo.RuleCase

  alias Archdo.Rules.CE.BoundaryTelemetry

  describe "CE-27 — boundary entry without telemetry span" do
    test "fires on Phoenix controller action with no telemetry" do
      code = ~S"""
      defmodule MyAppWeb.UserController do
        use Phoenix.Controller, namespace: MyAppWeb

        def show(conn, %{"id" => id}) do
          user = MyApp.Accounts.get_user!(id)
          render(conn, :show, user: user)
        end
      end
      """

      diags = analyze(BoundaryTelemetry, code, file: "lib/my_app_web/controllers/user_controller.ex")
      assert [diag] = diags
      assert diag.rule_id == "CE-27"
      assert diag.message =~ "show/2"
    end

    test "does NOT fire when controller action wraps work in :telemetry.span" do
      code = ~S"""
      defmodule MyAppWeb.UserController do
        use Phoenix.Controller, namespace: MyAppWeb

        def show(conn, %{"id" => id}) do
          :telemetry.span([:my_app_web, :user, :show], %{id: id}, fn ->
            user = MyApp.Accounts.get_user!(id)
            {render(conn, :show, user: user), %{}}
          end)
        end
      end
      """

      assert analyze(BoundaryTelemetry, code, file: "lib/my_app_web/controllers/user_controller.ex") == []
    end

    test "does NOT fire when telemetry.execute is called in the body" do
      code = ~S"""
      defmodule MyAppWeb.UserController do
        use Phoenix.Controller

        def show(conn, params) do
          :telemetry.execute([:my_app_web, :user, :show], %{}, %{params: params})
          render(conn, :show)
        end
      end
      """

      assert analyze(BoundaryTelemetry, code, file: "lib/my_app_web/controllers/user_controller.ex") == []
    end

    test "fires on Oban.Worker perform/1 with no telemetry" do
      code = ~S"""
      defmodule MyApp.Workers.SendEmail do
        use Oban.Worker, queue: :emails

        @impl Oban.Worker
        def perform(%Oban.Job{args: %{"user_id" => id}}) do
          MyApp.Mailer.send(id)
        end
      end
      """

      diags = analyze(BoundaryTelemetry, code, file: "lib/my_app/workers/send_email.ex")
      assert [diag] = diags
      assert diag.rule_id == "CE-27"
      assert diag.message =~ "perform/1"
    end

    test "fires on Mix.Task run/1 with no telemetry" do
      code = ~S"""
      defmodule Mix.Tasks.MyApp.Resync do
        use Mix.Task

        @impl Mix.Task
        def run(_args) do
          MyApp.Resync.go()
        end
      end
      """

      diags = analyze(BoundaryTelemetry, code, file: "lib/mix/tasks/my_app.resync.ex")
      assert [diag] = diags
      assert diag.rule_id == "CE-27"
    end

    test "does NOT fire on regular module (non-boundary)" do
      code = ~S"""
      defmodule MyApp.Helper do
        def go(x), do: x
      end
      """

      assert analyze(BoundaryTelemetry, code, file: "lib/my_app/helper.ex") == []
    end

    test "does NOT fire when @archdo_no_telemetry is set" do
      code = ~S"""
      defmodule MyAppWeb.HealthController do
        use Phoenix.Controller
        @archdo_no_telemetry "health endpoint — covered by k8s liveness probe"

        def show(conn, _params) do
          send_resp(conn, 200, "ok")
        end
      end
      """

      assert analyze(BoundaryTelemetry, code, file: "lib/my_app_web/controllers/health_controller.ex") == []
    end

    test "does NOT fire on LiveView handle_event (Phoenix emits its own telemetry)" do
      code = ~S"""
      defmodule MyAppWeb.PageLive do
        use Phoenix.LiveView

        @impl true
        def handle_event("save", _params, socket) do
          {:noreply, socket}
        end
      end
      """

      assert analyze(BoundaryTelemetry, code, file: "lib/my_app_web/live/page_live.ex") == []
    end
  end
end
