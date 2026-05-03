defmodule Archdo.Rules.Boundary.InternalStructAsEncoderTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Boundary.InternalStructAsEncoder

  describe "analyze/3 — flagged shapes" do
    test "flags @derive Jason.Encoder without :only on internal struct" do
      code = ~S"""
      defmodule MyApp.Orders.Order do
        @derive Jason.Encoder
        defstruct [:id, :user_id, :total, :status]
      end
      """

      diags =
        assert_flagged(InternalStructAsEncoder, code, file: "lib/my_app/orders/order.ex")

      diag = hd(diags)
      assert diag.severity == :warning
      assert diag.title =~ "Encoder"
    end

    test "flags @derive Jason.Encoder under nested context" do
      code = ~S"""
      defmodule MyApp.Catalog.Product do
        @derive Jason.Encoder
        defstruct [:id, :name, :price]
      end
      """

      assert_flagged(InternalStructAsEncoder, code, file: "lib/my_app/catalog/product.ex")
    end
  end

  describe "analyze/3 — accepted shapes" do
    test "allows @derive {Jason.Encoder, only: [...]}" do
      code = ~S"""
      defmodule MyApp.Orders.Order do
        @derive {Jason.Encoder, only: [:id, :user_id, :total]}
        defstruct [:id, :user_id, :total, :status]
      end
      """

      assert_clean(InternalStructAsEncoder, code, file: "lib/my_app/orders/order.ex")
    end

    test "allows @derive {Jason.Encoder, except: [...]}" do
      code = ~S"""
      defmodule MyApp.Orders.Order do
        @derive {Jason.Encoder, except: [:internal_state]}
        defstruct [:id, :total, :internal_state]
      end
      """

      assert_clean(InternalStructAsEncoder, code, file: "lib/my_app/orders/order.ex")
    end

    test "allows struct without any Jason derive" do
      code = ~S"""
      defmodule MyApp.Orders.Order do
        defstruct [:id, :total]
      end
      """

      assert_clean(InternalStructAsEncoder, code, file: "lib/my_app/orders/order.ex")
    end
  end

  describe "analyze/3 — out of scope" do
    test "does not flag a top-level context module (DTO at boundary)" do
      code = ~S"""
      defmodule MyApp.Orders do
        @derive Jason.Encoder
        defstruct [:id, :total]
      end
      """

      assert_clean(InternalStructAsEncoder, code, file: "lib/my_app/orders.ex")
    end

    test "does not flag a *_dto.ex module" do
      code = ~S"""
      defmodule MyApp.Orders.OrderDTO do
        @derive Jason.Encoder
        defstruct [:id, :total]
      end
      """

      assert_clean(InternalStructAsEncoder, code, file: "lib/my_app/orders/order_dto.ex")
    end

    test "does not flag a *_view.ex / *_json.ex module (Phoenix view)" do
      code = ~S"""
      defmodule MyAppWeb.OrderJSON do
        @derive Jason.Encoder
        defstruct [:id, :total]
      end
      """

      assert_clean(InternalStructAsEncoder, code,
        file: "lib/my_app_web/controllers/order_json.ex"
      )
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.Orders.OrderTest do
        @derive Jason.Encoder
        defstruct [:id]
      end
      """

      assert analyze(InternalStructAsEncoder, code, file: "test/my_app/orders/order_test.exs") ==
               []
    end
  end

  describe "id/0 and description/0" do
    test "rule id is stable" do
      assert InternalStructAsEncoder.id() == "1.22"
    end

    test "description mentions Jason or encoder" do
      desc = InternalStructAsEncoder.description()
      assert desc =~ "Jason" or desc =~ "encoder" or desc =~ "Encoder"
    end
  end
end
