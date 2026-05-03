defmodule Archdo.Rules.Boundary.RawMapInDomainTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Boundary.RawMapInDomain

  describe "analyze/3 — flagged shapes" do
    test "flags public function with bare map-shaped param threading to another module" do
      code = ~S"""
      defmodule MyApp.Orders do
        def place(params) do
          MyApp.PaymentGateway.charge(params)
        end
      end
      """

      diags = assert_flagged(RawMapInDomain, code, file: "lib/my_app/orders.ex")
      diag = hd(diags)
      assert diag.severity == :warning
      assert diag.title =~ "raw map" or diag.title =~ "Raw map"
    end

    test "flags `def f(%{} = params)` head threading raw map to another module" do
      code = ~S"""
      defmodule MyApp.Orders do
        def place(%{} = params) do
          MyApp.PaymentGateway.charge(params)
        end
      end
      """

      assert_flagged(RawMapInDomain, code, file: "lib/my_app/orders.ex")
    end

    test "flags `def f(params) when is_map(params)` head threading raw map" do
      code = ~S"""
      defmodule MyApp.Orders do
        def place(params) when is_map(params) do
          MyApp.PaymentGateway.charge(params)
        end
      end
      """

      assert_flagged(RawMapInDomain, code, file: "lib/my_app/orders.ex")
    end
  end

  describe "analyze/3 — allowed (DTO / changeset / validation present)" do
    test "allows function that calls Order.changeset/2" do
      code = ~S"""
      defmodule MyApp.Orders do
        def create(attrs) do
          %MyApp.Orders.Order{}
          |> MyApp.Orders.Order.changeset(attrs)
          |> MyApp.Repo.insert()
        end
      end
      """

      assert_clean(RawMapInDomain, code, file: "lib/my_app/orders.ex")
    end

    test "allows function that uses Ecto.Changeset.cast/3" do
      code = ~S"""
      defmodule MyApp.Orders do
        import Ecto.Changeset

        def create(attrs) do
          %MyApp.Orders.Order{}
          |> cast(attrs, [:total, :status])
          |> MyApp.Repo.insert()
        end
      end
      """

      assert_clean(RawMapInDomain, code, file: "lib/my_app/orders.ex")
    end

    test "allows function that calls a DTO new/1 constructor" do
      code = ~S"""
      defmodule MyApp.Orders do
        def place(params) do
          with {:ok, request} <- MyApp.Orders.PlaceOrderRequest.new(params) do
            MyApp.PaymentGateway.charge(request)
          end
        end
      end
      """

      assert_clean(RawMapInDomain, code, file: "lib/my_app/orders.ex")
    end

    test "allows function whose body destructures the map immediately" do
      code = ~S"""
      defmodule MyApp.Orders do
        def place(%{user_id: uid, total: total}) do
          MyApp.Billing.charge(uid, total)
        end
      end
      """

      assert_clean(RawMapInDomain, code, file: "lib/my_app/orders.ex")
    end
  end

  describe "analyze/3 — file scoping" do
    test "skips controllers (boundary/unvalidated_params handles those)" do
      code = ~S"""
      defmodule MyAppWeb.OrderController do
        use Phoenix.Controller

        def create(conn, params) do
          MyApp.Orders.place(params)
          send_resp(conn, 200, "ok")
        end
      end
      """

      assert_clean(RawMapInDomain, code, file: "lib/my_app_web/controllers/order_controller.ex")
    end

    test "skips LiveView (handled elsewhere)" do
      code = ~S"""
      defmodule MyAppWeb.OrderLive do
        use Phoenix.LiveView

        def handle_event("save", params, socket) do
          MyApp.Orders.place(params)
          {:noreply, socket}
        end
      end
      """

      assert_clean(RawMapInDomain, code, file: "lib/my_app_web/live/order_live.ex")
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.OrdersTest do
        def fixture(params), do: MyApp.External.do_thing(params)
      end
      """

      assert analyze(RawMapInDomain, code, file: "test/my_app/orders_test.exs") == []
    end
  end

  describe "id/0 and description/0" do
    test "rule id is stable" do
      assert RawMapInDomain.id() == "1.21"
    end

    test "description mentions raw map" do
      assert RawMapInDomain.description() =~ "map"
    end
  end
end
