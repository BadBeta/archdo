defmodule Archdo.Rules.Module.StacktraceInResponseTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.StacktraceInResponse

  describe "analyze/3 — controller files" do
    test "flags __STACKTRACE__ inside a controller's rescue → response" do
      code = ~S"""
      defmodule MyAppWeb.OrderController do
        use Phoenix.Controller

        def show(conn, params) do
          do_show(conn, params)
        rescue
          e ->
            json(conn, %{error: Exception.format(:error, e, __STACKTRACE__)})
        end
      end
      """

      diags =
        assert_flagged(StacktraceInResponse, code,
          file: "lib/my_app_web/controllers/order_controller.ex"
        )

      diag = hd(diags)
      assert diag.severity == :error
      assert diag.title =~ "STACKTRACE"
    end

    test "flags __STACKTRACE__ in controller bare interpolation" do
      code = ~S"""
      defmodule MyAppWeb.OrderController do
        use Phoenix.Controller

        def show(conn, params) do
          do_show(conn, params)
        rescue
          _e ->
            send_resp(conn, 500, "trace: #{inspect(__STACKTRACE__)}")
        end
      end
      """

      assert_flagged(StacktraceInResponse, code,
        file: "lib/my_app_web/controllers/order_controller.ex"
      )
    end
  end

  describe "analyze/3 — channel files" do
    test "flags __STACKTRACE__ inside a Phoenix channel" do
      code = ~S"""
      defmodule MyAppWeb.RoomChannel do
        use Phoenix.Channel

        def handle_in("msg", payload, socket) do
          do_work(payload)
          {:reply, :ok, socket}
        rescue
          e ->
            {:reply, {:error, %{trace: Exception.format(:error, e, __STACKTRACE__)}}, socket}
        end
      end
      """

      assert_flagged(StacktraceInResponse, code, file: "lib/my_app_web/channels/room_channel.ex")
    end
  end

  describe "analyze/3 — LiveView files" do
    test "flags __STACKTRACE__ inside a LiveView handle_event rescue" do
      code = ~S"""
      defmodule MyAppWeb.OrderLive do
        use Phoenix.LiveView

        def handle_event("save", params, socket) do
          do_save(params)
          {:noreply, socket}
        rescue
          e ->
            {:noreply, put_flash(socket, :error, Exception.format(:error, e, __STACKTRACE__))}
        end
      end
      """

      assert_flagged(StacktraceInResponse, code, file: "lib/my_app_web/live/order_live.ex")
    end
  end

  describe "analyze/3 — Logger usage is allowed" do
    test "allows __STACKTRACE__ inside Logger.error in a controller" do
      code = ~S"""
      defmodule MyAppWeb.OrderController do
        use Phoenix.Controller

        def show(conn, params) do
          do_show(conn, params)
        rescue
          e ->
            Logger.error(Exception.format(:error, e, __STACKTRACE__))
            send_resp(conn, 500, "Internal error")
        end
      end
      """

      assert_clean(StacktraceInResponse, code,
        file: "lib/my_app_web/controllers/order_controller.ex"
      )
    end

    test "allows __STACKTRACE__ inside :telemetry.execute" do
      code = ~S"""
      defmodule MyAppWeb.OrderController do
        use Phoenix.Controller

        def show(conn, params) do
          do_show(conn, params)
        rescue
          e ->
            :telemetry.execute([:err], %{}, %{stacktrace: __STACKTRACE__})
            send_resp(conn, 500, "Internal error")
        end
      end
      """

      assert_clean(StacktraceInResponse, code,
        file: "lib/my_app_web/controllers/order_controller.ex"
      )
    end
  end

  describe "analyze/3 — non-boundary files" do
    test "does not flag __STACKTRACE__ in lib/my_app/orders.ex (non-boundary)" do
      code = ~S"""
      defmodule MyApp.Orders do
        def place(attrs) do
          do_place(attrs)
        rescue
          e ->
            {:error, Exception.format(:error, e, __STACKTRACE__)}
        end
      end
      """

      assert_clean(StacktraceInResponse, code, file: "lib/my_app/orders.ex")
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyAppWeb.OrderControllerTest do
        def setup_error_case(conn) do
          do_setup(conn)
        rescue
          e ->
            json(conn, %{trace: Exception.format(:error, e, __STACKTRACE__)})
        end
      end
      """

      assert analyze(StacktraceInResponse, code,
               file: "test/my_app_web/controllers/order_controller_test.exs"
             ) == []
    end
  end

  describe "id/0 and description/0" do
    test "rule id is stable" do
      assert StacktraceInResponse.id() == "5.52"
    end

    test "description mentions stacktrace" do
      assert StacktraceInResponse.description() =~ "STACKTRACE"
    end
  end
end
