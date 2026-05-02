defmodule Archdo.Rules.CE.ComplexityShapeTest do
  use Archdo.RuleCase

  alias Archdo.Rules.CE.ComplexityShape

  describe "policy cells" do
    test "{:high_cyclo, :low_cogn} flat-dispatch fires CE-24-flat (info)" do
      # Many `case` clauses (each adds cyclomatic) but no nesting,
      # so cognitive stays low.
      code = ~S"""
      defmodule MyApp.Big do
        def kind(x) do
          case x do
            1 -> :a
            2 -> :b
            3 -> :c
            4 -> :d
            5 -> :e
            6 -> :f
            7 -> :g
            8 -> :h
            9 -> :i
            10 -> :j
            _ -> :other
          end
        end
      end
      """

      diags = assert_flagged(ComplexityShape, code, file: "lib/my_app/big.ex")
      assert hd(diags).rule_id == "CE-24-flat-dispatch"
      assert hd(diags).severity == :info
    end

    test "{:low_cyclo, :high_cogn} twisty-nested fires CE-24-twisty (warning)" do
      # Few branches but deeply nested → low cyclomatic, high cognitive.
      code = ~S"""
      defmodule MyApp.Twisty do
        def handle(x) do
          if x > 0 do
            if x > 10 do
              if x > 20 do
                if x > 30 do
                  if x > 40 do
                    :very_high
                  else
                    :high
                  end
                else
                  :upper_mid
                end
              else
                :mid
              end
            else
              :low
            end
          end
        end
      end
      """

      diags = assert_flagged(ComplexityShape, code, file: "lib/my_app/twisty.ex")
      assert Enum.any?(diags, &(&1.rule_id == "CE-24-twisty"))
    end

    test "{:low_cyclo, :low_cogn} simple function does NOT fire" do
      code = ~S"""
      defmodule MyApp.Plain do
        def double(x), do: x * 2
      end
      """

      assert_clean(ComplexityShape, code, file: "lib/my_app/plain.ex")
    end
  end
end
