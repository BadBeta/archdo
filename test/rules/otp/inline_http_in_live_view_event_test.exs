defmodule Archdo.Rules.OTP.InlineHttpInLiveViewEventTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.InlineHttpInLiveViewEvent

  describe "blocking HTTP in LiveView handle_event" do
    test "flags Req.get inside handle_event" do
      code = ~S"""
      defmodule MyAppWeb.UserLive do
        use Phoenix.LiveView

        def handle_event("fetch", _, socket) do
          {:ok, response} = Req.get("https://api.example.com/users")
          {:noreply, assign(socket, users: response.body)}
        end
      end
      """

      [diag] = assert_flagged(InlineHttpInLiveViewEvent, code)
      assert diag.rule_id == "5.76"
      assert diag.severity == :warning
      assert diag.message =~ "Req"
    end

    test "flags HTTPoison.post inside handle_event" do
      code = ~S"""
      defmodule MyAppWeb.OrderLive do
        use Phoenix.LiveView

        def handle_event("submit", params, socket) do
          {:ok, _resp} = HTTPoison.post("https://api/orders", params)
          {:noreply, socket}
        end
      end
      """

      [diag] = assert_flagged(InlineHttpInLiveViewEvent, code)
      assert diag.message =~ "HTTPoison"
    end

    test "flags Tesla.get inside handle_event" do
      code = ~S"""
      defmodule MyAppWeb.UserLive do
        use Phoenix.LiveView

        def handle_event("load", _params, socket) do
          {:ok, env} = Tesla.get(client(), "/users")
          {:noreply, assign(socket, users: env.body)}
        end

        defp client, do: Tesla.client([])
      end
      """

      [diag] = assert_flagged(InlineHttpInLiveViewEvent, code)
      assert diag.message =~ "Tesla"
    end

    test "flags Finch.request inside handle_event" do
      code = ~S"""
      defmodule MyAppWeb.SearchLive do
        use Phoenix.LiveView

        def handle_event("search", %{"q" => q}, socket) do
          {:ok, _resp} = Finch.build(:get, "/q?#{q}") |> Finch.request(MyApp.Finch)
          {:noreply, socket}
        end
      end
      """

      [diag] = assert_flagged(InlineHttpInLiveViewEvent, code)
      assert diag.message =~ "Finch"
    end

    test "flags use MyAppWeb, :live_view convention too" do
      code = ~S"""
      defmodule MyAppWeb.UserLive do
        use MyAppWeb, :live_view

        def handle_event("go", _, socket) do
          Req.get("https://x")
          {:noreply, socket}
        end
      end
      """

      assert_flagged(InlineHttpInLiveViewEvent, code)
    end
  end

  describe "clean code" do
    test "does not flag Req.get inside start_async" do
      code = ~S"""
      defmodule MyAppWeb.UserLive do
        use Phoenix.LiveView

        def handle_event("fetch", _params, socket) do
          {:noreply, start_async(socket, :fetch_users, fn ->
            Req.get!("https://api.example.com/users")
          end)}
        end
      end
      """

      assert_clean(InlineHttpInLiveViewEvent, code)
    end

    test "does not flag HTTP outside LiveView module" do
      code = ~S"""
      defmodule MyApp.UserClient do
        def fetch do
          Req.get("https://api/users")
        end
      end
      """

      assert_clean(InlineHttpInLiveViewEvent, code)
    end

    test "does not flag handle_event with no HTTP call" do
      code = ~S"""
      defmodule MyAppWeb.CounterLive do
        use Phoenix.LiveView

        def handle_event("inc", _, socket) do
          {:noreply, update(socket, :count, &(&1 + 1))}
        end
      end
      """

      assert_clean(InlineHttpInLiveViewEvent, code)
    end

    test "does not flag HTTP in non-handle_event callback" do
      # mount/3 with HTTP is a separate concern (rule 1: connected? guard).
      # This rule scopes specifically to handle_event/3.
      code = ~S"""
      defmodule MyAppWeb.UserLive do
        use Phoenix.LiveView

        def mount(_, _, socket) do
          {:ok, response} = Req.get("https://api/users")
          {:ok, assign(socket, users: response.body)}
        end
      end
      """

      assert_clean(InlineHttpInLiveViewEvent, code)
    end

    test "does not flag test files" do
      code = ~S"""
      defmodule MyAppWeb.UserLiveTest do
        use Phoenix.LiveView

        def handle_event("fetch", _, socket) do
          Req.get("https://x")
          {:noreply, socket}
        end
      end
      """

      assert_clean(InlineHttpInLiveViewEvent, code, file: "test/user_live_test.exs")
    end
  end
end
