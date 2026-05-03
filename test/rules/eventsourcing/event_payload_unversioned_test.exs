defmodule Archdo.Rules.EventSourcing.EventPayloadUnversionedTest do
  use Archdo.RuleCase

  alias Archdo.Rules.EventSourcing.EventPayloadUnversioned

  describe "analyze/3 — flagged shapes" do
    test "flags event struct without version field or @version attribute" do
      code = ~S"""
      defmodule MyApp.Events.OrderPlaced do
        defstruct [:order_id, :user_id, :total, :placed_at]
      end
      """

      diags =
        assert_flagged(EventPayloadUnversioned, code, file: "lib/my_app/events/order_placed.ex")

      diag = hd(diags)
      assert diag.severity == :warning
      assert diag.title =~ "version"
    end

    test "flags command struct without version" do
      code = ~S"""
      defmodule MyApp.Commands.PlaceOrder do
        defstruct [:order_id, :user_id, :total]
      end
      """

      assert_flagged(EventPayloadUnversioned, code, file: "lib/my_app/commands/place_order.ex")
    end
  end

  describe "analyze/3 — accepted shapes" do
    test "allows event with :version field" do
      code = ~S"""
      defmodule MyApp.Events.OrderPlaced do
        defstruct [:version, :order_id, :user_id, :total]
      end
      """

      assert_clean(EventPayloadUnversioned, code, file: "lib/my_app/events/order_placed.ex")
    end

    test "allows event with :schema_version field" do
      code = ~S"""
      defmodule MyApp.Events.OrderPlaced do
        defstruct [:schema_version, :order_id, :user_id, :total]
      end
      """

      assert_clean(EventPayloadUnversioned, code, file: "lib/my_app/events/order_placed.ex")
    end

    test "allows event with :event_version field" do
      code = ~S"""
      defmodule MyApp.Events.OrderPlaced do
        defstruct [:event_version, :order_id, :user_id, :total]
      end
      """

      assert_clean(EventPayloadUnversioned, code, file: "lib/my_app/events/order_placed.ex")
    end

    test "allows event with @version attribute and version default" do
      code = ~S"""
      defmodule MyApp.Events.OrderPlaced do
        @version 1
        defstruct version: @version, order_id: nil, user_id: nil, total: nil
      end
      """

      assert_clean(EventPayloadUnversioned, code, file: "lib/my_app/events/order_placed.ex")
    end
  end

  describe "analyze/3 — out of scope" do
    test "does not flag plain (non-event) struct" do
      code = ~S"""
      defmodule MyApp.Domain.Settings do
        defstruct [:host, :port]
      end
      """

      assert_clean(EventPayloadUnversioned, code, file: "lib/my_app/domain/settings.ex")
    end

    test "does not flag a struct outside Events / Commands namespace" do
      code = ~S"""
      defmodule MyApp.Models.Order do
        defstruct [:order_id, :total]
      end
      """

      assert_clean(EventPayloadUnversioned, code, file: "lib/my_app/models/order.ex")
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.Events.OrderPlacedTest do
        defstruct [:order_id]
      end
      """

      assert analyze(EventPayloadUnversioned, code,
               file: "test/my_app/events/order_placed_test.exs"
             ) == []
    end
  end

  describe "id/0 and description/0" do
    test "rule id is stable" do
      assert EventPayloadUnversioned.id() == "8.9"
    end

    test "description mentions version" do
      assert EventPayloadUnversioned.description() =~ "version"
    end
  end
end
