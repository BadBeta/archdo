defmodule Archdo.Rules.Module.EnumCountEmptyCheckTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.EnumCountEmptyCheck

  describe "analyze/3" do
    test "flags length(x) == 0" do
      code = ~S"""
      defmodule MyApp.Checker do
        def empty?(list) do
          length(list) == 0
        end
      end
      """

      diags = assert_flagged(EnumCountEmptyCheck, code)
      diag = hd(diags)
      assert diag.rule_id == "6.47"
      assert diag.severity == :info
    end

    test "flags length(x) > 0" do
      code = ~S"""
      defmodule MyApp.Checker do
        def non_empty?(list) do
          length(list) > 0
        end
      end
      """

      diags = assert_flagged(EnumCountEmptyCheck, code)
      assert hd(diags).rule_id == "6.47"
    end

    test "flags Enum.count(x) == 0" do
      code = ~S"""
      defmodule MyApp.Checker do
        def empty?(items) do
          Enum.count(items) == 0
        end
      end
      """

      diags = assert_flagged(EnumCountEmptyCheck, code)
      assert hd(diags).rule_id == "6.47"
    end

    test "flags Enum.count(x) != 0" do
      code = ~S"""
      defmodule MyApp.Checker do
        def has_items?(items) do
          Enum.count(items) != 0
        end
      end
      """

      diags = assert_flagged(EnumCountEmptyCheck, code)
      assert hd(diags).rule_id == "6.47"
    end

    test "allows length(x) == some_other_number" do
      code = ~S"""
      defmodule MyApp.Checker do
        def exactly_three?(list) do
          length(list) == 3
        end
      end
      """

      assert_clean(EnumCountEmptyCheck, code)
    end

    test "allows match?-based empty check" do
      code = ~S"""
      defmodule MyApp.Checker do
        def empty?(list), do: match?([], list)
        def non_empty?(list), do: match?([_ | _], list)
      end
      """

      assert_clean(EnumCountEmptyCheck, code)
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.CheckerTest do
        def check(list) do
          length(list) == 0
        end
      end
      """

      assert analyze(EnumCountEmptyCheck, code, file: "test/checker_test.exs") == []
    end
  end
end
