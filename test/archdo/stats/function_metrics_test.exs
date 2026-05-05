defmodule Archdo.Stats.FunctionMetricsTest do
  use ExUnit.Case, async: true

  alias Archdo.Stats.FunctionMetrics

  defp module_ast(code) do
    {:ok, ast} = Code.string_to_quoted(code)
    ast
  end

  defp metric_for(metrics, name) do
    Enum.find(metrics, fn m -> m.name == name end) ||
      flunk("no metric for #{name} in #{inspect(Enum.map(metrics, & &1.name))}")
  end

  describe "analyze/1 — per-function metrics" do
    test "single-expression function has 1 statement and 1 return point" do
      ast =
        module_ast("""
        defmodule M do
          def f(x), do: x + 1
        end
        """)

      [m] = FunctionMetrics.analyze(ast)

      assert m.name == :f
      assert m.arity == 1
      assert m.statements == 1
      assert m.return_points == 1
      assert m.params == 1
    end

    test "function with case has one return point per clause" do
      ast =
        module_ast("""
        defmodule M do
          def classify(n) do
            case n do
              1 -> :one
              2 -> :two
              3 -> :three
            end
          end
        end
        """)

      m = FunctionMetrics.analyze(ast) |> metric_for(:classify)

      assert m.return_points == 3
    end

    test "with-chain bodies count as do-body + each else clause" do
      # 1 (do body) + 1 (single else clause) = 2 return points
      ast =
        module_ast("""
        defmodule M do
          def fetch(arg) do
            with {:ok, x} <- step(arg) do
              {:ok, x}
            else
              {:error, _} = e -> e
            end
          end
        end
        """)

      m = FunctionMetrics.analyze(ast) |> metric_for(:fetch)

      assert m.return_points == 2
    end

    test "rebinding the same name doesn't double-count locals" do
      ast =
        module_ast("""
        defmodule M do
          def run do
            state = init()
            state = update(state)
            state
          end
        end
        """)

      m = FunctionMetrics.analyze(ast) |> metric_for(:run)

      # `state` is rebound twice but counts as ONE distinct local.
      assert m.locals == 1
    end

    test "function-head pattern bindings don't count as locals; arity reflects head args" do
      ast =
        module_ast("""
        defmodule M do
          def show(%User{id: id}), do: id
        end
        """)

      m = FunctionMetrics.analyze(ast) |> metric_for(:show)

      assert m.params == 1
      # `id` is bound by the head pattern, not by `=` in the body.
      assert m.locals == 0
    end
  end
end
