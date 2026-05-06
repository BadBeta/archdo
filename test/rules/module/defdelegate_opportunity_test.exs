defmodule Archdo.Rules.Module.DefdelegateOpportunityTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.DefdelegateOpportunity

  test "fires on `def f(x), do: OtherMod.f(x)` (1-line forward, args match)" do
    code = ~S"""
    defmodule MyApp.Catalog do
      def get_product!(id), do: MyApp.Catalog.Product.fetch!(id)
    end
    """

    diags = assert_flagged(DefdelegateOpportunity, code)
    assert hd(diags).rule_id == "6.86"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "defdelegate"
  end

  test "does NOT fire on `defdelegate get_product!(id), to: ...` (already idiomatic)" do
    code = ~S"""
    defmodule MyApp.Catalog do
      defdelegate get_product!(id), to: MyApp.Catalog.Product, as: :fetch!
    end
    """

    assert_clean(DefdelegateOpportunity, code)
  end

  test "does NOT fire when the body adds logic beyond the forward call" do
    code = ~S"""
    defmodule MyApp.Catalog do
      def get_product!(id) do
        :telemetry.execute([:catalog, :get], %{}, %{id: id})
        MyApp.Catalog.Product.fetch!(id)
      end
    end
    """

    assert_clean(DefdelegateOpportunity, code)
  end

  test "does NOT fire when the args don't match (transformation present)" do
    code = ~S"""
    defmodule MyApp.Catalog do
      def get_product!(id), do: MyApp.Catalog.Product.fetch!(to_string(id))
    end
    """

    assert_clean(DefdelegateOpportunity, code)
  end
end
