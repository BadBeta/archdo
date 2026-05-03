defmodule Archdo.Rules.OTP.AsyncDropsLoggerMetadataTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.AsyncDropsLoggerMetadata

  describe "analyze/3 — Task.Supervisor.start_child" do
    test "flags closure that logs without restoring metadata" do
      code = ~S"""
      defmodule MyApp.Orders do
        require Logger

        def place(order) do
          Task.Supervisor.start_child(MyApp.TaskSup, fn ->
            Logger.info("processing order")
            do_work(order)
          end)
        end
      end
      """

      diags = assert_flagged(AsyncDropsLoggerMetadata, code, file: "lib/my_app/orders.ex")
      diag = hd(diags)
      assert diag.severity == :warning
      assert diag.title =~ "metadata"
    end

    test "allows closure that sets Logger.metadata" do
      code = ~S"""
      defmodule MyApp.Orders do
        require Logger

        def place(order) do
          metadata = Logger.metadata()
          Task.Supervisor.start_child(MyApp.TaskSup, fn ->
            Logger.metadata(metadata)
            Logger.info("processing order")
            do_work(order)
          end)
        end
      end
      """

      assert_clean(AsyncDropsLoggerMetadata, code, file: "lib/my_app/orders.ex")
    end
  end

  describe "analyze/3 — Task.async" do
    test "flags Task.async closure that logs without metadata" do
      code = ~S"""
      defmodule MyApp.Orders do
        require Logger

        def fetch_all(urls) do
          tasks = Enum.map(urls, fn url ->
            Task.async(fn ->
              Logger.info("fetching url")
              fetch(url)
            end)
          end)
          Enum.map(tasks, &Task.await/1)
        end
      end
      """

      assert_flagged(AsyncDropsLoggerMetadata, code, file: "lib/my_app/orders.ex")
    end

    test "allows Task.async closure that does not log" do
      code = ~S"""
      defmodule MyApp.Orders do
        def fetch_all(urls) do
          tasks = Enum.map(urls, fn url ->
            Task.async(fn -> fetch(url) end)
          end)
          Enum.map(tasks, &Task.await/1)
        end
      end
      """

      # Closure does no logging itself — metadata propagation not required
      assert_clean(AsyncDropsLoggerMetadata, code, file: "lib/my_app/orders.ex")
    end
  end

  describe "analyze/3 — Task.async_stream" do
    test "flags Task.async_stream closure that logs without metadata" do
      code = ~S"""
      defmodule MyApp.Orders do
        require Logger

        def process(orders) do
          orders
          |> Task.async_stream(fn order ->
            Logger.info("processing #{order.id}")
            do_work(order)
          end)
          |> Enum.to_list()
        end
      end
      """

      assert_flagged(AsyncDropsLoggerMetadata, code, file: "lib/my_app/orders.ex")
    end
  end

  describe "analyze/3 — :telemetry.execute" do
    test "flags closure that emits telemetry without metadata" do
      code = ~S"""
      defmodule MyApp.Orders do
        def place(order) do
          Task.Supervisor.start_child(MyApp.TaskSup, fn ->
            :telemetry.execute([:order, :placed], %{count: 1}, %{order_id: order.id})
            do_work(order)
          end)
        end
      end
      """

      assert_flagged(AsyncDropsLoggerMetadata, code, file: "lib/my_app/orders.ex")
    end
  end

  describe "analyze/3 — function captures (out of cross-module scope)" do
    test "does not flag function-capture form (cannot see across modules)" do
      code = ~S"""
      defmodule MyApp.Orders do
        def place(order) do
          Task.Supervisor.start_child(MyApp.TaskSup, &MyApp.Worker.process/1, [order])
        end
      end
      """

      assert_clean(AsyncDropsLoggerMetadata, code, file: "lib/my_app/orders.ex")
    end
  end

  describe "analyze/3 — file scoping" do
    test "skips test files" do
      code = ~S"""
      defmodule MyApp.OrdersTest do
        require Logger
        def fixture do
          Task.async(fn -> Logger.info("test") end)
        end
      end
      """

      assert analyze(AsyncDropsLoggerMetadata, code, file: "test/my_app/orders_test.exs") ==
               []
    end
  end

  describe "id/0 and description/0" do
    test "rule id is stable" do
      assert AsyncDropsLoggerMetadata.id() == "5.55"
    end

    test "description mentions metadata or context" do
      desc = AsyncDropsLoggerMetadata.description()
      assert desc =~ "metadata" or desc =~ "context"
    end
  end
end
