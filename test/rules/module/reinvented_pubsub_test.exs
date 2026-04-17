defmodule Archdo.Rules.Module.ReinventedPubSubTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.ReinventedPubSub

  describe "analyze/3" do
    test "flags hand-rolled pubsub with subscriber list" do
      code = ~S"""
      defmodule MyApp.EventBus do
        use GenServer

        def subscribe(topic) do
          subscribers = get_subscribers(topic)
          send(__MODULE__, {:subscribe, topic, self()})
        end

        def broadcast(topic, message) do
          send(__MODULE__, {:broadcast, topic, message})
        end

        def init(_) do
          {:ok, %{subscribers: []}}
        end

        def handle_info({:subscribe, topic, pid}, state) do
          {:noreply, state}
        end
      end
      """

      diags = assert_flagged(ReinventedPubSub, code)
      assert hd(diags).rule_id == "4.15"
      assert hd(diags).message =~ "subscriber list"
    end

    test "allows module using Phoenix.PubSub" do
      code = ~S"""
      defmodule MyApp.Notifications do
        def subscribe(topic) do
          Phoenix.PubSub.subscribe(MyApp.PubSub, topic)
        end

        def broadcast(topic, message) do
          Phoenix.PubSub.broadcast(MyApp.PubSub, topic, message)
        end
      end
      """

      assert_clean(ReinventedPubSub, code)
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.EventBusTest do
        use GenServer

        def subscribe(topic), do: :ok
        def broadcast(topic, msg), do: :ok
      end
      """

      assert_clean(ReinventedPubSub, code, file: "test/event_bus_test.exs")
    end
  end
end
