defmodule Archdo.Rules.Module.UnnecessaryRecursionTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.UnnecessaryRecursion

  describe "analyze/3" do
    test "flags classic [head|tail] recursion with [] base case" do
      code = ~S"""
      defmodule MyApp.Sum do
        def sum([]), do: 0
        def sum([h | t]), do: h + sum(t)
      end
      """

      diags = assert_flagged(UnnecessaryRecursion, code, file: "lib/sum.ex")
      assert hd(diags).rule_id == "6.21"
      assert hd(diags).message =~ "sum/1"
    end

    test "does NOT flag when there is only a [head|tail] clause (no [] base)" do
      code = ~S"""
      defmodule MyApp.Sum do
        def sum([h | t]), do: h + sum(t)
      end
      """

      assert_clean(UnnecessaryRecursion, code, file: "lib/sum.ex")
    end

    test "does NOT flag when there is only an [] clause (no recursion)" do
      code = ~S"""
      defmodule MyApp.Sum do
        def sum([]), do: 0
      end
      """

      assert_clean(UnnecessaryRecursion, code, file: "lib/sum.ex")
    end

    test "does NOT flag when [head|tail] clause does not call self" do
      code = ~S"""
      defmodule MyApp.First do
        def first([]), do: nil
        def first([h | _t]), do: h
      end
      """

      assert_clean(UnnecessaryRecursion, code, file: "lib/first.ex")
    end

    test "does not run on test files" do
      code = ~S"""
      defmodule MyApp.SumTest do
        def sum([]), do: 0
        def sum([h | t]), do: h + sum(t)
      end
      """

      assert_clean(UnnecessaryRecursion, code, file: "test/sum_test.exs")
    end

    test "flags multi-arity recursion" do
      code = ~S"""
      defmodule MyApp.Build do
        def build(list), do: build(list, [])
        def build([], acc), do: Enum.reverse(acc)
        def build([h | t], acc), do: build(t, [h * 2 | acc])
      end
      """

      diags = assert_flagged(UnnecessaryRecursion, code, file: "lib/build.ex")
      assert Enum.any?(diags, &(&1.message =~ "build/2"))
    end
  end
end
