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

    test "does NOT flag multi-clause helper with catch-all literal-arg fallback" do
      # The `defp css(_), do: css("default")` clause is technically a self-call,
      # but it dispatches once with a literal argument and terminates. The `<>`
      # in the named clauses is a 2-string-literal concat, not a loop. Flagging
      # this is the BUG-3 false positive seen in PhiaUI's CSS-class helpers.
      code = ~S"""
      defmodule MyApp.Css do
        defp css("default") do
          "rounded-md bg-primary " <>
            "focus-visible:ring-2 " <>
            "px-4 py-2"
        end

        defp css("outline") do
          "border border-input " <>
            "px-4 py-2"
        end

        defp css(_), do: css("default")
      end
      """

      assert_clean(StringConcatInLoop, code)
    end

    test "still flags real iterative recursion with <> on accumulator" do
      code = ~S"""
      defmodule MyApp.Builder do
        defp build([], acc), do: acc
        defp build([h | t], acc), do: build(t, acc <> to_string(h))
      end
      """

      diagnostics = assert_flagged(StringConcatInLoop, code)
      assert hd(diagnostics).rule_id == "6.46"
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
