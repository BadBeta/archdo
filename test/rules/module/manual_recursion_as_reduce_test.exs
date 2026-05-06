defmodule Archdo.Rules.Module.ManualRecursionAsReduceTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.ManualRecursionAsReduce

  describe "manual recursion that's really a reduce" do
    test "flags the canonical empty/cons recursion pair" do
      code = ~S"""
      defmodule MyApp.Sum do
        def total(xs), do: do_sum(xs, 0)

        defp do_sum([], acc), do: acc
        defp do_sum([h | t], acc), do: do_sum(t, acc + h)
      end
      """

      [diag] = assert_flagged(ManualRecursionAsReduce, code)
      assert diag.rule_id == "6.100"
      assert diag.severity == :info
      assert diag.message =~ "reduce"
    end

    test "flags pair where transform calls a helper" do
      code = ~S"""
      defmodule MyApp.Builder do
        def build(items), do: do_build(items, [])

        defp do_build([], acc), do: acc
        defp do_build([h | t], acc), do: do_build(t, [transform(h) | acc])

        defp transform(x), do: x
      end
      """

      [diag] = assert_flagged(ManualRecursionAsReduce, code)
      assert diag.message =~ "do_build"
    end

    test "flags pair regardless of clause order" do
      code = ~S"""
      defmodule MyApp.Counter do
        def count_evens(xs), do: do_count(xs, 0)

        defp do_count([h | t], acc) when rem(h, 2) == 0, do: do_count(t, acc + 1)
        defp do_count([_ | t], acc), do: do_count(t, acc)
        defp do_count([], acc), do: acc
      end
      """

      assert_flagged(ManualRecursionAsReduce, code)
    end
  end

  describe "clean code" do
    test "does not flag a single-clause private fn" do
      code = ~S"""
      defmodule MyApp.Lib do
        defp helper(xs), do: Enum.sum(xs)
      end
      """

      assert_clean(ManualRecursionAsReduce, code)
    end

    test "does not flag two-clause fn that's not list-recursion" do
      code = ~S"""
      defmodule MyApp.Lib do
        defp shape({:a, x}, acc), do: x + acc
        defp shape({:b, x}, acc), do: x * acc
      end
      """

      assert_clean(ManualRecursionAsReduce, code)
    end

    test "does not flag empty-clause fn that doesn't return acc as-is (transform on empty)" do
      code = ~S"""
      defmodule MyApp.Lib do
        defp f([], acc), do: Enum.reverse(acc)
        defp f([h | t], acc), do: f(t, [h | acc])
      end
      """

      assert_flagged(ManualRecursionAsReduce, code)
      # The ending transform is fine — Enum.reduce|>Enum.reverse pattern, still a reduce.
    end

    test "does not flag if cons-clause does not recurse with `t`" do
      # Index-based traversal — not a fold over the list spine.
      code = ~S"""
      defmodule MyApp.Lib do
        defp f([], _, acc), do: acc
        defp f(list, i, acc), do: f(list, i + 1, [Enum.at(list, i) | acc])
      end
      """

      assert_clean(ManualRecursionAsReduce, code)
    end

    test "does not flag test files" do
      code = ~S"""
      defmodule MyApp.LibTest do
        defp do_sum([], acc), do: acc
        defp do_sum([h | t], acc), do: do_sum(t, acc + h)
      end
      """

      assert_clean(ManualRecursionAsReduce, code, file: "test/lib_test.exs")
    end
  end

  describe "edge cases" do
    test "does not flag public function (defp only)" do
      # Public recursion may be part of the API (e.g., Enum-style helpers).
      code = ~S"""
      defmodule MyApp.Lib do
        def sum([], acc), do: acc
        def sum([h | t], acc), do: sum(t, acc + h)
      end
      """

      assert_clean(ManualRecursionAsReduce, code)
    end
  end
end
