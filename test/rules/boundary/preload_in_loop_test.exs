defmodule Archdo.Rules.Boundary.PreloadInLoopTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Boundary.PreloadInLoop

  describe "analyze/3" do
    test "flags Repo.preload inside Enum.map" do
      code = ~S"""
      defmodule MyApp.Orders do
        def list_with_items(orders) do
          Enum.map(orders, fn order ->
            MyApp.Repo.preload(order, [:items])
          end)
        end
      end
      """

      diags = assert_flagged(PreloadInLoop, code, file: "lib/my_app/orders.ex")
      assert hd(diags).rule_id == "4.28"
      assert hd(diags).severity == :warning
      assert hd(diags).message =~ "Enum.map"
    end

    test "flags Repo.get inside Enum.each" do
      code = ~S"""
      defmodule MyApp.Notifications do
        def notify_all(user_ids) do
          Enum.each(user_ids, fn id ->
            user = MyApp.Repo.get(MyApp.User, id)
            send_notification(user)
          end)
        end
      end
      """

      diags = assert_flagged(PreloadInLoop, code, file: "lib/my_app/notifications.ex")
      assert hd(diags).message =~ "Enum.each"
    end

    test "flags Repo.one inside for comprehension" do
      code = ~S"""
      defmodule MyApp.Reports do
        import Ecto.Query

        def build_report(ids) do
          for id <- ids do
            MyApp.Repo.one(from u in MyApp.User, where: u.id == ^id)
          end
        end
      end
      """

      diags = assert_flagged(PreloadInLoop, code, file: "lib/my_app/reports.ex")
      assert hd(diags).message =~ "for comprehension"
    end

    test "allows Repo.preload outside loop" do
      code = ~S"""
      defmodule MyApp.Orders do
        def list_with_items(orders) do
          orders = MyApp.Repo.preload(orders, [:items])
          Enum.map(orders, &format_order/1)
        end
      end
      """

      assert_clean(PreloadInLoop, code, file: "lib/my_app/orders.ex")
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.OrdersTest do
        use ExUnit.Case

        test "preloads in loop for test setup" do
          orders = Enum.map(order_ids, fn id ->
            MyApp.Repo.get(MyApp.Order, id)
          end)
          assert length(orders) == 3
        end
      end
      """

      assert_clean(PreloadInLoop, code, file: "test/my_app/orders_test.exs")
    end
  end
end
