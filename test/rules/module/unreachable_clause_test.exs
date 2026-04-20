defmodule Archdo.Rules.Module.UnreachableClauseTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.UnreachableClause

  describe "case with catch-all before specific clauses" do
    test "flags _ before specific patterns" do
      code = ~S"""
      defmodule MyApp.Parser do
        def parse(input) do
          case input do
            _ -> :default
            {:ok, val} -> val
            {:error, reason} -> reason
          end
        end
      end
      """

      diagnostics = assert_flagged(UnreachableClause, code)
      assert [diag] = diagnostics
      assert diag.rule_id == "6.35"
      assert diag.severity == :warning
      assert diag.context.construct == :case
      assert diag.message =~ "catch-all pattern"
    end

    test "flags bare variable before specific patterns" do
      code = ~S"""
      defmodule MyApp.Handler do
        def handle(msg) do
          case msg do
            x -> {:caught, x}
            :ping -> :pong
            :hello -> :world
          end
        end
      end
      """

      diagnostics = assert_flagged(UnreachableClause, code)
      assert [diag] = diagnostics
      assert diag.rule_id == "6.35"
    end

    test "does not flag _ as last clause" do
      code = ~S"""
      defmodule MyApp.Handler do
        def handle(msg) do
          case msg do
            :ping -> :pong
            :hello -> :world
            _ -> :unknown
          end
        end
      end
      """

      assert_clean(UnreachableClause, code)
    end

    test "does not flag specific patterns only" do
      code = ~S"""
      defmodule MyApp.Handler do
        def handle(msg) do
          case msg do
            {:ok, val} -> val
            {:error, reason} -> reason
          end
        end
      end
      """

      assert_clean(UnreachableClause, code)
    end
  end

  describe "cond with true before last clause" do
    test "flags true -> before other clauses" do
      code = ~S"""
      defmodule MyApp.Classifier do
        def classify(x) do
          cond do
            true -> :default
            x > 10 -> :large
            x > 0 -> :small
          end
        end
      end
      """

      diagnostics = assert_flagged(UnreachableClause, code)
      assert [diag] = diagnostics
      assert diag.rule_id == "6.35"
      assert diag.context.construct == :cond
      assert diag.message =~ "true ->"
    end

    test "does not flag true -> as last clause (idiomatic)" do
      code = ~S"""
      defmodule MyApp.Classifier do
        def classify(x) do
          cond do
            x > 10 -> :large
            x > 0 -> :small
            true -> :default
          end
        end
      end
      """

      assert_clean(UnreachableClause, code)
    end
  end

  describe "test file skipping" do
    test "does not flag test files" do
      code = ~S"""
      defmodule MyApp.ParserTest do
        def example do
          case input do
            _ -> :default
            :specific -> :value
          end
        end
      end
      """

      assert_clean(UnreachableClause, code, file: "test/parser_test.exs")
    end
  end
end
