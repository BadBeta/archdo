defmodule Archdo.Rules.Module.CodeEvalStringOrQuotedTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.CodeEvalStringOrQuoted

  describe "analyze/3" do
    test "flags Code.eval_string/1" do
      code = ~S"""
      defmodule MyApp.Calculator do
        def compute(expr) do
          {result, _} = Code.eval_string(expr)
          result
        end
      end
      """

      diags =
        assert_flagged(CodeEvalStringOrQuoted, code, file: "lib/my_app/calculator.ex")

      assert hd(diags).rule_id == "6.93"
    end

    test "flags Code.eval_quoted/1" do
      code = ~S"""
      defmodule MyApp.Repl do
        def run(quoted) do
          Code.eval_quoted(quoted)
        end
      end
      """

      assert_flagged(CodeEvalStringOrQuoted, code, file: "lib/my_app/repl.ex")
    end

    test "ignores Code.format_string!" do
      code = ~S"""
      defmodule MyApp.Format do
        def pretty(src), do: Code.format_string!(src)
      end
      """

      assert_clean(CodeEvalStringOrQuoted, code, file: "lib/my_app/format.ex")
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.CalculatorTest do
        def expr(s), do: Code.eval_string(s)
      end
      """

      assert_clean(CodeEvalStringOrQuoted, code, file: "test/calculator_test.exs")
    end

    test "skips Mix tasks (Code.eval used during compile / build)" do
      code = ~S"""
      defmodule Mix.Tasks.MyApp.Eval do
        def run([src]), do: Code.eval_string(src)
      end
      """

      assert_clean(CodeEvalStringOrQuoted, code, file: "lib/mix/tasks/my_app.eval.ex")
    end
  end
end
