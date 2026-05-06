defmodule Archdo.Rules.Module.ParseInEnumLambdaTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.ParseInEnumLambda

  describe "analyze/3" do
    test "flags Decimal.new inside Enum.map lambda" do
      code = ~S"""
      defmodule MyApp.Pricing do
        def total(items, _rate) do
          items
          |> Enum.map(fn item ->
            Decimal.mult(item.amount, Decimal.new("1.20"))
          end)
          |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
        end
      end
      """

      diags = assert_flagged(ParseInEnumLambda, code, file: "lib/my_app/pricing.ex")
      assert hd(diags).rule_id == "6.90"
    end

    test "flags Date.from_iso8601! inside Enum.filter lambda" do
      code = ~S"""
      defmodule MyApp.Reports do
        def by_date(rows, cutoff_str) do
          Enum.filter(rows, fn row ->
            Date.compare(row.date, Date.from_iso8601!(cutoff_str)) == :gt
          end)
        end
      end
      """

      assert_flagged(ParseInEnumLambda, code, file: "lib/my_app/reports.ex")
    end

    test "ignores Decimal.new outside any lambda" do
      code = ~S"""
      defmodule MyApp.Pricing do
        def constant_rate, do: Decimal.new("1.20")
      end
      """

      assert_clean(ParseInEnumLambda, code, file: "lib/my_app/pricing.ex")
    end

    test "ignores construct OUTSIDE the lambda but operating on the result" do
      code = ~S"""
      defmodule MyApp.Pricing do
        def total(items) do
          rate = Decimal.new("1.20")

          Enum.map(items, fn item -> Decimal.mult(item.amount, rate) end)
        end
      end
      """

      assert_clean(ParseInEnumLambda, code, file: "lib/my_app/pricing.ex")
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.PricingTest do
        def cases do
          Enum.map([1, 2], fn x -> Decimal.new(x) end)
        end
      end
      """

      assert_clean(ParseInEnumLambda, code, file: "test/pricing_test.exs")
    end
  end
end
