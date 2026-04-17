defmodule Archdo.Rules.EventSourcing.ProcessManagerReadsProjectionTest do
  use Archdo.RuleCase

  alias Archdo.Rules.EventSourcing.ProcessManagerReadsProjection

  describe "analyze/3" do
    test "flags Repo.get inside process manager" do
      code = ~S"""
      defmodule MyApp.ProcessManagers.OrderFulfillment do
        use Commanded.ProcessManagers.ProcessManager, name: "OrderFulfillment"

        def handle(state, %OrderPlaced{} = event) do
          user = MyApp.Repo.get!(MyApp.User, event.user_id)
          %ShipOrder{address: user.address}
        end
      end
      """

      diags = assert_flagged(ProcessManagerReadsProjection, code)
      assert hd(diags).rule_id == "8.7"
      assert hd(diags).message =~ "Repo.get"
    end

    test "allows process manager without Repo reads" do
      code = ~S"""
      defmodule MyApp.ProcessManagers.OrderFulfillment do
        use Commanded.ProcessManagers.ProcessManager, name: "OrderFulfillment"

        def handle(state, %OrderPlaced{} = event) do
          %ShipOrder{order_id: event.order_id, address: state.address}
        end
      end
      """

      assert_clean(ProcessManagerReadsProjection, code)
    end

    test "ignores non-process-manager modules" do
      code = ~S"""
      defmodule MyApp.Orders do
        def get_order(id), do: MyApp.Repo.get!(MyApp.Order, id)
      end
      """

      assert_clean(ProcessManagerReadsProjection, code)
    end
  end
end
