defmodule Archdo.Rules.Module.ConstantExpressionTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.ConstantExpression

  describe "if with constant condition" do
    test "flags if true" do
      code = ~S"""
      defmodule MyApp.Debug do
        def run do
          if true do
            IO.puts("always runs")
          end
        end
      end
      """

      diagnostics = assert_flagged(ConstantExpression, code)
      assert [diag] = diagnostics
      assert diag.rule_id == "6.42"
      assert diag.severity == :info
      assert diag.context.construct == :if
      assert diag.message =~ "always taken"
    end

    test "flags if false" do
      code = ~S"""
      defmodule MyApp.Debug do
        def run do
          if false do
            IO.puts("never runs")
          end
        end
      end
      """

      diagnostics = assert_flagged(ConstantExpression, code)
      assert [diag] = diagnostics
      assert diag.message =~ "never taken"
    end

    test "does not flag if with variable condition" do
      code = ~S"""
      defmodule MyApp.Logic do
        def run(flag) do
          if flag do
            :yes
          end
        end
      end
      """

      assert_clean(ConstantExpression, code)
    end

    test "does not flag if with function call condition" do
      code = ~S"""
      defmodule MyApp.Logic do
        def run(data) do
          if valid?(data) do
            process(data)
          end
        end

        defp valid?(_), do: true
      end
      """

      assert_clean(ConstantExpression, code)
    end
  end

  describe "cond with true as first clause" do
    test "flags true as first clause with more clauses after" do
      code = ~S"""
      defmodule MyApp.Router do
        def route(path) do
          cond do
            true -> :default
            path == "/home" -> :home
            path == "/about" -> :about
          end
        end
      end
      """

      diagnostics = assert_flagged(ConstantExpression, code)
      assert [diag] = diagnostics
      assert diag.rule_id == "6.42"
      assert diag.context.construct == :cond
      assert diag.message =~ "first clause"
    end

    test "does not flag true as last clause (idiomatic)" do
      code = ~S"""
      defmodule MyApp.Router do
        def route(path) do
          cond do
            path == "/home" -> :home
            path == "/about" -> :about
            true -> :not_found
          end
        end
      end
      """

      assert_clean(ConstantExpression, code)
    end

    test "does not flag cond with single true clause" do
      code = ~S"""
      defmodule MyApp.Always do
        def run do
          cond do
            true -> :always
          end
        end
      end
      """

      assert_clean(ConstantExpression, code)
    end
  end

  describe "test file skipping" do
    test "does not flag test files" do
      code = ~S"""
      defmodule MyApp.DebugTest do
        def example do
          if true do
            :test_helper
          end
        end
      end
      """

      assert_clean(ConstantExpression, code, file: "test/debug_test.exs")
    end
  end
end
