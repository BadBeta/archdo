defmodule Archdo.Rules.OTP.MissingHandleAsyncTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.MissingHandleAsync

  test "fires when LiveView calls start_async/3 but defines no handle_async/3" do
    code = ~S"""
    defmodule MyAppWeb.UserLive do
      use Phoenix.LiveView

      def mount(_params, _session, socket) do
        {:ok, start_async(socket, :load_user, fn -> fetch_user() end)}
      end

      defp fetch_user, do: %{name: "Jane"}
    end
    """

    diags = assert_flagged(MissingHandleAsync, code, file: "lib/my_app_web/live/user_live.ex")
    assert hd(diags).rule_id == "5.57"
    assert hd(diags).severity == :warning
    assert hd(diags).message =~ "handle_async"
  end

  test "does NOT fire when handle_async/3 is defined" do
    code = ~S"""
    defmodule MyAppWeb.UserLive do
      use Phoenix.LiveView

      def mount(_params, _session, socket) do
        {:ok, start_async(socket, :load_user, fn -> fetch_user() end)}
      end

      def handle_async(:load_user, {:ok, user}, socket) do
        {:noreply, assign(socket, :user, user)}
      end

      defp fetch_user, do: %{name: "Jane"}
    end
    """

    assert_clean(MissingHandleAsync, code, file: "lib/my_app_web/live/user_live.ex")
  end

  test "does NOT fire on a non-LiveView module that happens to call start_async" do
    # `start_async` only carries the Phoenix.LiveView semantics inside
    # an LV. A worker module with the same name is unrelated.
    code = ~S"""
    defmodule MyApp.Worker do
      def go(socket) do
        start_async(socket, :load_user, fn -> :ok end)
      end
    end
    """

    assert_clean(MissingHandleAsync, code, file: "lib/my_app/worker.ex")
  end
end
