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

    test "allows module using Registry for fan-out" do
      code = ~S"""
      defmodule MyApp.Notifications do
        def subscribe(topic) do
          Registry.register(MyApp.Reg, topic, [])
        end

        def broadcast(topic, msg) do
          Registry.dispatch(MyApp.Reg, topic, fn entries ->
            for {pid, _} <- entries, do: send(pid, msg)
          end)
        end
      end
      """

      assert_clean(ReinventedPubSub, code)
    end

    test "allows module using :pg" do
      code = ~S"""
      defmodule MyApp.Notifications do
        def subscribe(topic), do: :pg.join(:my_app, topic, self())
        def broadcast(topic, msg) do
          for pid <- :pg.get_members(:my_app, topic), do: send(pid, msg)
        end
      end
      """

      assert_clean(ReinventedPubSub, code)
    end

    test "does not flag a module that has subscribe but no broadcast" do
      code = ~S"""
      defmodule MyApp.Notifications do
        use GenServer
        def subscribe(_topic), do: :ok
        def init(_), do: {:ok, %{subscribers: []}}
      end
      """

      assert_clean(ReinventedPubSub, code)
    end

    test "does not flag a module that has both names but does not maintain a subscriber list" do
      code = ~S"""
      defmodule MyApp.Notifications do
        def subscribe(_topic), do: :ok
        def broadcast(_topic, _msg), do: :ok
      end
      """

      assert_clean(ReinventedPubSub, code)
    end
  end
end
