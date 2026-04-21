defmodule Archdo.Rules.Module.StringConcatInLoopTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.StringConcatInLoop

  describe "analyze/3" do
    test "flags Enum.reduce with empty string init and <> concat" do
      code = ~S"""
      defmodule MyApp.Builder do
        def build(items) do
          Enum.reduce(items, "", fn item, acc ->
            acc <> to_string(item) <> "\n"
          end)
        end
      end
      """

      diags = assert_flagged(StringConcatInLoop, code)
      diag = hd(diags)
      assert diag.rule_id == "6.46"
      assert diag.severity == :warning
    end

    test "flags for comprehension with reduce: empty string and <> concat" do
      code = ~S"""
      defmodule MyApp.Formatter do
        def format(lines) do
          for line <- lines, reduce: "" do
            acc -> acc <> String.trim(line) <> "\n"
          end
        end
      end
      """

      diags = assert_flagged(StringConcatInLoop, code)
      assert hd(diags).rule_id == "6.46"
    end

    test "allows Enum.reduce with non-string accumulator" do
      code = ~S"""
      defmodule MyApp.Counter do
        def count(items) do
          Enum.reduce(items, 0, fn _item, acc ->
            acc + 1
          end)
        end
      end
      """

      assert_clean(StringConcatInLoop, code)
    end

    test "allows Enum.reduce with string init but no concat" do
      code = ~S"""
      defmodule MyApp.Picker do
        def pick(items) do
          Enum.reduce(items, "", fn item, _acc ->
            item
          end)
        end
      end
      """

      assert_clean(StringConcatInLoop, code)
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.BuilderTest do
        def build(items) do
          Enum.reduce(items, "", fn item, acc ->
            acc <> to_string(item)
          end)
        end
      end
      """

      assert analyze(StringConcatInLoop, code, file: "test/builder_test.exs") == []
    end
  end
end
