defmodule Archdo.Rules.Module.FunctionComplexityTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.FunctionComplexity

  test "flags public function with arity > 5" do
    code = ~S"""
    defmodule MyApp.Complex do
      @moduledoc "Public module"
      def too_many(a, b, c, d, e, f) do
        {a, b, c, d, e, f}
      end
    end
    """

    diags = assert_flagged(FunctionComplexity, code)
    assert Enum.any?(diags, &(&1.title == "High function arity"))
  end

  test "allows function with arity <= 5" do
    code = ~S"""
    defmodule MyApp.Simple do
      @moduledoc false
      def ok(a, b, c) do
        {a, b, c}
      end
    end
    """

    assert_clean(FunctionComplexity, code)
  end

  test "flags high cyclomatic complexity for twisty-nested code" do
    # Twisty-nested: high cyclomatic AND high cognitive (nested control flow,
    # not flat dispatch). 6.2 fires; CE-24 would also fire as :twisty.
    code = """
    defmodule MyApp.Twisty do
      @moduledoc false
      def go(x, y, z) do
        if x > 0 do
          if y > 0 do
            if z > 0 do
              case x + y + z do
                n when n > 100 -> :high
                n when n > 50 -> :mid
                _ -> :low
              end
            else
              if x > y, do: :left, else: :right
            end
          else
            cond do
              x > 10 and y < 0 -> :a
              x < 5 or z > 0 -> :b
              true -> :c
            end
          end
        else
          :neg
        end
      end
    end
    """

    diags = assert_flagged(FunctionComplexity, code)
    assert Enum.any?(diags, &(&1.message =~ "cyclomatic complexity"))
  end

  test "does NOT flag flat-dispatch shapes (CE-24 covers them)" do
    # Pure dispatch table: cyclomatic high, cognitive ~0. CE-24-flat-dispatch
    # surfaces this informationally; 6.2 should defer instead of double-firing.
    branches =
      Enum.map_join(1..12, "\n", fn i ->
        "      :val_#{i} -> :result_#{i}"
      end)

    code = """
    defmodule MyApp.FlatDispatch do
      @moduledoc false
      def lookup(x) do
        case x do
    #{branches}
          _ -> :unknown
        end
      end
    end
    """

    assert_clean(FunctionComplexity, code)
  end
end
