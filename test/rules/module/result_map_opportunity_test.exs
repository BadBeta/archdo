defmodule Archdo.Rules.Module.ResultMapOpportunityTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.ResultMapOpportunity

  describe "Result.map opportunity" do
    test "flags case that wraps ok and forwards bound error" do
      code = ~S"""
      defmodule MyApp.Orders do
        def fetch_total(id) do
          case fetch_order(id) do
            {:ok, order} -> {:ok, order.total}
            {:error, _} = e -> e
          end
        end

        defp fetch_order(_), do: {:ok, nil}
      end
      """

      [diag] = assert_flagged(ResultMapOpportunity, code)
      assert diag.rule_id == "6.96"
      assert diag.severity == :info
      assert diag.message =~ "Result.map"
    end

    test "flags case that wraps ok and rebuilds error tuple" do
      code = ~S"""
      defmodule MyApp.Users do
        def get_email(id) do
          case fetch_user(id) do
            {:ok, user} -> {:ok, user.email}
            {:error, reason} -> {:error, reason}
          end
        end

        defp fetch_user(_), do: {:ok, nil}
      end
      """

      [diag] = assert_flagged(ResultMapOpportunity, code)
      assert diag.message =~ "Result.map"
    end

    test "flags case where ok branch builds a literal map from bound var" do
      code = ~S"""
      defmodule MyApp.Service do
        def handle(input) do
          case parse(input) do
            {:ok, parsed} -> {:ok, %{value: parsed, ts: 0}}
            {:error, _} = e -> e
          end
        end

        defp parse(_), do: {:ok, 1}
      end
      """

      [diag] = assert_flagged(ResultMapOpportunity, code)
      assert diag.message =~ "Result.map"
    end

    test "flags multiple instances in same module" do
      code = ~S"""
      defmodule MyApp.Service do
        def a(x) do
          case fetch(x) do
            {:ok, v} -> {:ok, v + 1}
            {:error, _} = e -> e
          end
        end

        def b(x) do
          case lookup(x) do
            {:ok, v} -> {:ok, transform(v)}
            {:error, reason} -> {:error, reason}
          end
        end

        defp fetch(x), do: {:ok, x}
        defp lookup(x), do: {:ok, x}
        defp transform(x), do: x
      end
      """

      diagnostics = assert_flagged(ResultMapOpportunity, code)
      assert length(diagnostics) == 2
    end
  end

  describe "clean code" do
    test "does not flag case with ok-branch returning bare value (not wrapped)" do
      code = ~S"""
      defmodule MyApp.Service do
        def get(x) do
          case fetch(x) do
            {:ok, v} -> v
            {:error, _} -> nil
          end
        end

        defp fetch(_), do: {:ok, 1}
      end
      """

      assert_clean(ResultMapOpportunity, code)
    end

    test "does not flag case with three or more clauses" do
      code = ~S"""
      defmodule MyApp.Service do
        def get(x) do
          case fetch(x) do
            {:ok, v} when v > 0 -> {:ok, v}
            {:ok, _} -> {:error, :non_positive}
            {:error, _} = e -> e
          end
        end

        defp fetch(x), do: {:ok, x}
      end
      """

      assert_clean(ResultMapOpportunity, code)
    end

    test "does not flag case where error branch returns transformed error" do
      code = ~S"""
      defmodule MyApp.Service do
        def get(x) do
          case fetch(x) do
            {:ok, v} -> {:ok, v}
            {:error, _} -> {:error, :wrapped}
          end
        end

        defp fetch(_), do: {:ok, 1}
      end
      """

      assert_clean(ResultMapOpportunity, code)
    end

    test "does not flag case dispatching on non-result shape" do
      code = ~S"""
      defmodule MyApp.Router do
        def dispatch(msg) do
          case msg do
            {:cmd, c} -> {:ok, c}
            {:event, e} -> {:event, e}
          end
        end
      end
      """

      assert_clean(ResultMapOpportunity, code)
    end

    test "does not flag test files" do
      code = ~S"""
      defmodule MyApp.OrdersTest do
        def helper(x) do
          case fetch(x) do
            {:ok, v} -> {:ok, v + 1}
            {:error, _} = e -> e
          end
        end

        defp fetch(_), do: {:ok, 1}
      end
      """

      assert_clean(ResultMapOpportunity, code, file: "test/orders_test.exs")
    end
  end

  describe "edge cases" do
    test "flags case with `_ = e` binding on error tuple" do
      code = ~S"""
      defmodule MyApp.Service do
        def run(x) do
          case fetch(x) do
            {:ok, v} -> {:ok, transform(v)}
            {:error, _} = err -> err
          end
        end

        defp fetch(_), do: {:ok, 1}
        defp transform(v), do: v
      end
      """

      [diag] = assert_flagged(ResultMapOpportunity, code)
      assert diag.rule_id == "6.96"
    end

    test "does not flag when error binding name doesn't match return" do
      # Variable name mismatch — caller is doing something else
      code = ~S"""
      defmodule MyApp.Service do
        def run(x) do
          case fetch(x) do
            {:ok, v} -> {:ok, v}
            {:error, _} = e -> {:error, transform(e)}
          end
        end

        defp fetch(_), do: {:ok, 1}
        defp transform(_), do: nil
      end
      """

      assert_clean(ResultMapOpportunity, code)
    end
  end
end
