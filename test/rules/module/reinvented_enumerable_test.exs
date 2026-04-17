defmodule Archdo.Rules.Module.ReinventedEnumerableTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.ReinventedEnumerable

  describe "analyze/3" do
    test "flags recursive function using Enum.at" do
      code = ~S"""
      defmodule MyApp.Utils do
        def walk(list, n, acc \\ [])
        def walk(_list, 0, acc), do: acc
        def walk(list, n, acc) do
          item = Enum.at(list, n)
          walk(list, n - 1, [item | acc])
        end
      end
      """

      diags = assert_flagged(ReinventedEnumerable, code)
      assert hd(diags).rule_id == "3.5"
      assert hd(diags).message =~ "Enum.at"
    end

    test "allows non-recursive use of Enum.at" do
      code = ~S"""
      defmodule MyApp.Utils do
        def first(list), do: Enum.at(list, 0)
      end
      """

      assert_clean(ReinventedEnumerable, code)
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.UtilsTest do
        def walk(list, n, acc \\ [])
        def walk(_list, 0, acc), do: acc
        def walk(list, n, acc) do
          item = Enum.at(list, n)
          walk(list, n - 1, [item | acc])
        end
      end
      """

      assert_clean(ReinventedEnumerable, code, file: "test/utils_test.exs")
    end
  end
end
