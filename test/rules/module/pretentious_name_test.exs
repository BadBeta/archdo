defmodule Archdo.Rules.Module.PretentiousNameTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.PretentiousName

  describe "analyze/3" do
    test "flags module ending in Manager" do
      code = ~S"""
      defmodule MyApp.UserManager do
        def create(attrs), do: {:ok, attrs}
      end
      """

      diags = assert_flagged(PretentiousName, code)
      assert hd(diags).rule_id == "6.7"
      assert hd(diags).message =~ "Manager"
    end

    test "flags module ending in Helper" do
      code = ~S"""
      defmodule MyApp.StringHelper do
        def format(s), do: s
      end
      """

      assert_flagged(PretentiousName, code)
    end

    test "flags module ending in Utils" do
      code = ~S"""
      defmodule MyApp.DateUtils do
        def today, do: Date.utc_today()
      end
      """

      assert_flagged(PretentiousName, code)
    end

    test "allows module with descriptive name" do
      code = ~S"""
      defmodule MyApp.PriceCalculator do
        def calculate(product, qty), do: product.price * qty
      end
      """

      assert_clean(PretentiousName, code)
    end

    test "allows Worker suffix (legitimate OTP convention)" do
      code = ~S"""
      defmodule MyApp.EmailWorker do
        use Oban.Worker
        def perform(job), do: :ok
      end
      """

      assert_clean(PretentiousName, code)
    end
  end
end
