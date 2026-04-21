defmodule Archdo.Rules.Boundary.LogicInLiveviewTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Boundary.LogicInLiveview

  describe "analyze/3" do
    test "flags handle_event with too many non-assign AST nodes" do
      code = ~S"""
      defmodule MyAppWeb.OrderLive do
        use Phoenix.LiveView

        def handle_event("submit_order", params, socket) do
          user = socket.assigns.current_user
          items = parse_items(params["items"])
          subtotal = Enum.reduce(items, 0, fn item, acc -> acc + item.price * item.qty end)
          tax = subtotal * 0.08
          total = subtotal + tax
          discount = calculate_discount(user, total)
          final = total - discount
          order = %{user_id: user.id, items: items, total: final, tax: tax, discount: discount}
          result = MyApp.Orders.create(order)
          case result do
            {:ok, order} -> {:noreply, assign(socket, :order, order)}
            {:error, reason} -> {:noreply, assign(socket, :error, reason)}
          end
        end
      end
      """

      diags = assert_flagged(LogicInLiveview, code, file: "lib/my_app_web/live/order_live.ex")
      assert hd(diags).rule_id == "1.27"
      assert hd(diags).message =~ "handle_event"
    end

    test "allows thin handle_event with just delegation and assign" do
      code = ~S"""
      defmodule MyAppWeb.UserLive do
        use Phoenix.LiveView

        def handle_event("save", params, socket) do
          {:noreply, assign(socket, :result, MyApp.Accounts.update(params))}
        end
      end
      """

      assert_clean(LogicInLiveview, code, file: "lib/my_app_web/live/user_live.ex")
    end

    test "skips non-LiveView modules" do
      code = ~S"""
      defmodule MyApp.Worker do
        use GenServer

        def handle_event(event, state) do
          complex_logic = Enum.reduce(event.items, %{}, fn item, acc ->
            Map.update(acc, item.category, [item], &[item | &1])
          end)
          processed = transform(complex_logic)
          validated = validate(processed)
          enriched = enrich(validated)
          {:ok, enriched}
        end
      end
      """

      assert_clean(LogicInLiveview, code, file: "lib/my_app/worker.ex")
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyAppWeb.OrderLiveTest do
        use ExUnit.Case

        def handle_event("test", params, socket) do
          complex = Enum.reduce(params, %{}, fn {k, v}, acc -> Map.put(acc, k, process(v)) end)
          more = transform(complex)
          even_more = validate(more)
          final = enrich(even_more)
          result = store(final)
          {:noreply, assign(socket, :result, result)}
        end
      end
      """

      assert_clean(LogicInLiveview, code, file: "test/my_app_web/live/order_live_test.exs")
    end
  end
end
