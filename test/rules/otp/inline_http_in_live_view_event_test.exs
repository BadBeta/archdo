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

  describe "indirect HTTP via project-level taint set" do
    defp parse(code, file) do
      {:ok, ast} = Code.string_to_quoted(code, file: file, columns: true)
      {file, ast}
    end

    test "flags handle_event calling a Module.fun that wraps Tesla.delete" do
      lv =
        parse(
          ~S"""
          defmodule MyAppWeb.LogDrainsLive do
            use Phoenix.LiveView

            def handle_event("delete", %{"id" => id}, socket) do
              {:ok, _} = MyApp.Vercel.Client.delete_log_drain(id)
              {:noreply, socket}
            end
          end
          """,
          "lib/my_app_web/log_drains_live.ex"
        )

      client =
        parse(
          ~S"""
          defmodule MyApp.Vercel.Client do
            def delete_log_drain(id) do
              Tesla.delete("/log-drains/" <> id)
            end
          end
          """,
          "lib/my_app/vercel/client.ex"
        )

      diags = InlineHttpInLiveViewEvent.analyze_project([lv, client])
      assert [_ | _] = diags
      assert Enum.any?(diags, &(&1.rule_id == "5.76"))
    end

    test "flags transitive 2-hop chain (handle_event → middle → Tesla)" do
      lv =
        parse(
          ~S"""
          defmodule MyAppWeb.OrderLive do
            use Phoenix.LiveView

            def handle_event("ship", %{"id" => id}, socket) do
              MyApp.Shipping.ship_order(id)
              {:noreply, socket}
            end
          end
          """,
          "lib/my_app_web/order_live.ex"
        )

      shipping =
        parse(
          ~S"""
          defmodule MyApp.Shipping do
            def ship_order(id), do: MyApp.Shipping.Carrier.dispatch(id)
          end
          """,
          "lib/my_app/shipping.ex"
        )

      carrier =
        parse(
          ~S"""
          defmodule MyApp.Shipping.Carrier do
            def dispatch(id), do: Tesla.post("/dispatch", %{id: id})
          end
          """,
          "lib/my_app/shipping/carrier.ex"
        )

      diags = InlineHttpInLiveViewEvent.analyze_project([lv, shipping, carrier])
      assert [_ | _] = diags
    end

    test "does not flag transitive call inside start_async wrapper" do
      lv =
        parse(
          ~S"""
          defmodule MyAppWeb.AsyncLive do
            use Phoenix.LiveView

            def handle_event("fetch", _, socket) do
              {:noreply,
               start_async(socket, :fetch, fn ->
                 MyApp.ApiClient.fetch_users()
               end)}
            end
          end
          """,
          "lib/my_app_web/async_live.ex"
        )

      api =
        parse(
          ~S"""
          defmodule MyApp.ApiClient do
            def fetch_users, do: Tesla.get("/users")
          end
          """,
          "lib/my_app/api_client.ex"
        )

      assert [] = InlineHttpInLiveViewEvent.analyze_project([lv, api])
    end

    test "does not flag past depth-5 transitive chain" do
      lv =
        parse(
          ~S"""
          defmodule MyAppWeb.DeepLive do
            use Phoenix.LiveView

            def handle_event("go", _, socket) do
              MyApp.A.f(:x)
              {:noreply, socket}
            end
          end
          """,
          "lib/my_app_web/deep_live.ex"
        )

      chain =
        parse(
          ~S"""
          defmodule MyApp.A do
            def f(x), do: MyApp.B.g(x)
          end

          defmodule MyApp.B do
            def g(x), do: MyApp.C.h(x)
          end

          defmodule MyApp.C do
            def h(x), do: MyApp.D.i(x)
          end

          defmodule MyApp.D do
            def i(x), do: MyApp.E.j(x)
          end

          defmodule MyApp.E do
            def j(x), do: MyApp.F.k(x)
          end

          defmodule MyApp.F do
            def k(x), do: MyApp.G.l(x)
          end

          defmodule MyApp.G do
            def l(_x), do: Tesla.get("/end-of-the-line")
          end
          """,
          "lib/my_app/chain.ex"
        )

      assert [] = InlineHttpInLiveViewEvent.analyze_project([lv, chain])
    end
  end
end
