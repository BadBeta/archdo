defmodule Archdo.Rules.Module.BrokenTailRecursionTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.BrokenTailRecursion

  describe "analyze/3" do
    test "flags try/rescue breaking TCO" do
      code = ~S"""
      defmodule MyApp.Processor do
        def process([], acc), do: acc
        def process([h | t], acc) do
          try do
            result = transform(h)
            process(t, [result | acc])
          rescue
            _ -> process(t, acc)
          end
        end
      end
      """

      diags = assert_flagged(BrokenTailRecursion, code)
      assert hd(diags).rule_id == "6.22"
      assert hd(diags).message =~ "try/rescue"
    end

    test "flags pipe after recursive call" do
      code = ~S"""
      defmodule MyApp.Debug do
        def transform([], acc), do: Enum.reverse(acc)
        def transform([h | t], acc) do
          transform(t, [h | acc]) |> IO.inspect()
        end
      end
      """

      diags = assert_flagged(BrokenTailRecursion, code)
      assert hd(diags).rule_id == "6.22"
      assert hd(diags).message =~ "pipe"
    end

    test "flags binary op after recursive call" do
      code = ~S"""
      defmodule MyApp.Builder do
        def build([], acc), do: acc
        def build([h | t], acc) do
          build(t, acc) <> to_string(h)
        end
      end
      """

      diags = assert_flagged(BrokenTailRecursion, code)
      assert hd(diags).rule_id == "6.22"
    end

    test "allows clean tail recursion" do
      code = ~S"""
      defmodule MyApp.Processor do
        def process([], acc), do: Enum.reverse(acc)
        def process([h | t], acc) do
          process(t, [transform(h) | acc])
        end
      end
      """

      assert_clean(BrokenTailRecursion, code)
    end

    test "allows non-recursive functions" do
      code = ~S"""
      defmodule MyApp.Utils do
        def add(a, b), do: a + b
      end
      """

      assert_clean(BrokenTailRecursion, code)
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.Test do
        def helper([], acc), do: acc
        def helper([h | t], acc) do
          try do
            helper(t, [h | acc])
          rescue
            _ -> acc
          end
        end
      end
      """

      assert_clean(BrokenTailRecursion, code, file: "test/helper_test.exs")
    end
  end
end
