defmodule Archdo.Rules.CE.UntestedBuildingBlockTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.CE.UntestedBuildingBlock

  defp parse(file, code) do
    {:ok, ast} =
      Code.string_to_quoted(code,
        file: file,
        columns: true,
        token_metadata: true,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    {file, ast}
  end

  describe "CE-55 — building block without a property test" do
    test "fires on a building-block function with no property test" do
      file_asts = [
        parse("lib/myapp/pricing.ex", ~S"""
        defmodule MyApp.Pricing do
          @spec discount(integer(), float()) :: integer()
          def discount(price, rate), do: max(0, price - round(price * rate))
        end
        """)
      ]

      diags = UntestedBuildingBlock.analyze_project(file_asts)
      assert [diag] = diags
      assert diag.rule_id == "CE-55"
      assert diag.message =~ "MyApp.Pricing"
      assert diag.message =~ "discount/2"
    end

    test "does NOT fire when a property block calls the function" do
      file_asts = [
        parse("lib/myapp/pricing.ex", ~S"""
        defmodule MyApp.Pricing do
          @spec discount(integer(), float()) :: integer()
          def discount(price, rate), do: max(0, price - round(price * rate))
        end
        """),
        parse("test/myapp/pricing_test.exs", ~S"""
        defmodule MyApp.PricingTest do
          use ExUnit.Case, async: true
          use ExUnitProperties

          property "discount never produces negative" do
            check all price <- positive_integer(), rate <- float() do
              assert MyApp.Pricing.discount(price, rate) >= 0
            end
          end
        end
        """)
      ]

      assert UntestedBuildingBlock.analyze_project(file_asts) == []
    end

    test "does NOT fire on a non-building-block (score < 0.9)" do
      # Missing @spec drops output_completeness — function isn't a building
      # block, CE-55 doesn't apply
      file_asts = [
        parse("lib/myapp/util.ex", ~S"""
        defmodule MyApp.Util do
          def go(x), do: x
        end
        """)
      ]

      assert UntestedBuildingBlock.analyze_project(file_asts) == []
    end

    test "does NOT fire when @archdo_no_property is set on the module" do
      file_asts = [
        parse("lib/myapp/locked.ex", ~S"""
        defmodule MyApp.Locked do
          @archdo_no_property "covered by integration tests against external system"

          @spec compute(integer()) :: integer()
          def compute(x), do: x * 2
        end
        """)
      ]

      assert UntestedBuildingBlock.analyze_project(file_asts) == []
    end

    test "regular ExUnit tests do NOT count as property coverage" do
      # A regular `test "..."` block calling the function is good but isn't
      # the property test the rule wants.
      file_asts = [
        parse("lib/myapp/pricing.ex", ~S"""
        defmodule MyApp.Pricing do
          @spec discount(integer(), float()) :: integer()
          def discount(price, rate), do: max(0, price - round(price * rate))
        end
        """),
        parse("test/myapp/pricing_test.exs", ~S"""
        defmodule MyApp.PricingTest do
          use ExUnit.Case, async: true

          test "discount of 100 at 0.10 is 90" do
            assert MyApp.Pricing.discount(100, 0.10) == 90
          end
        end
        """)
      ]

      diags = UntestedBuildingBlock.analyze_project(file_asts)
      assert [_] = diags
    end

    test "fires once per building-block function (not duplicated across modules)" do
      file_asts = [
        parse("lib/myapp/a.ex", ~S"""
        defmodule MyApp.A do
          @spec a(integer()) :: integer()
          def a(x), do: x

          @spec b(integer()) :: integer()
          def b(x), do: x * 2
        end
        """)
      ]

      diags = UntestedBuildingBlock.analyze_project(file_asts)
      assert length(diags) == 2
      assert Enum.any?(diags, &(&1.message =~ "a/1"))
      assert Enum.any?(diags, &(&1.message =~ "b/1"))
    end

    test "fires once for a multi-clause function, not once per clause" do
      # `admin?/1` with two clauses (`is_binary` guard + catch-all)
      # should produce one diagnostic, not two.
      file_asts = [
        parse("lib/myapp/admin.ex", ~S"""
        defmodule MyApp.Admin do
          @spec admin?(any()) :: boolean()
          def admin?(email) when is_binary(email), do: email == "root@example.com"
          def admin?(_), do: false
        end
        """)
      ]

      diags = UntestedBuildingBlock.analyze_project(file_asts)

      admin_diags = Enum.filter(diags, &(&1.message =~ "admin?/1"))
      assert length(admin_diags) == 1
    end
  end

  describe "pack assignment" do
    test "rule pack is :ce_composability (opt-in)" do
      assert UntestedBuildingBlock.pack() == :ce_composability
    end
  end
end
