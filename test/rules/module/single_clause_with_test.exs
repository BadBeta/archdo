defmodule Archdo.Rules.Module.SingleClauseWithTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.SingleClauseWith

  describe "single-clause with" do
    test "flags with expression having exactly one <- clause" do
      code = ~S"""
      defmodule MyApp.Users do
        def create(attrs) do
          with {:ok, user} <- validate(attrs) do
            {:ok, user}
          end
        end

        defp validate(attrs), do: {:ok, attrs}
      end
      """

      diagnostics = assert_flagged(SingleClauseWith, code)
      assert [diag] = diagnostics
      assert diag.rule_id == "6.41"
      assert diag.severity == :info
      assert diag.message =~ "case"
    end

    test "flags single-clause with that has an else block" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def fetch(id) do
          with {:ok, user} <- find_user(id) do
            {:ok, user}
          else
            {:error, _} -> {:error, :not_found}
          end
        end

        defp find_user(id), do: {:ok, %{id: id}}
      end
      """

      diagnostics = assert_flagged(SingleClauseWith, code)
      assert [diag] = diagnostics
      assert diag.message =~ "case"
    end

    test "flags multiple single-clause withs in the same module" do
      code = ~S"""
      defmodule MyApp.Service do
        def action_a(x) do
          with {:ok, val} <- step_a(x) do
            val
          end
        end

        def action_b(y) do
          with {:ok, val} <- step_b(y) do
            val
          end
        end

        defp step_a(x), do: {:ok, x}
        defp step_b(y), do: {:ok, y}
      end
      """

      diagnostics = assert_flagged(SingleClauseWith, code)
      assert length(diagnostics) == 2
    end
  end

  describe "clean code" do
    test "does not flag with having two or more <- clauses" do
      code = ~S"""
      defmodule MyApp.Orders do
        def place_order(user_id, product_id) do
          with {:ok, user} <- fetch_user(user_id),
               {:ok, product} <- fetch_product(product_id) do
            {:ok, create_order(user, product)}
          end
        end

        defp fetch_user(id), do: {:ok, %{id: id}}
        defp fetch_product(id), do: {:ok, %{id: id}}
        defp create_order(user, product), do: %{user: user, product: product}
      end
      """

      assert_clean(SingleClauseWith, code)
    end

    test "does not flag test files" do
      code = ~S"""
      defmodule MyApp.OrdersTest do
        def helper do
          with {:ok, val} <- something() do
            val
          end
        end

        defp something, do: {:ok, 1}
      end
      """

      assert_clean(SingleClauseWith, code, file: "test/orders_test.exs")
    end

    test "does not flag modules without with expressions" do
      code = ~S"""
      defmodule MyApp.Math do
        def add(a, b), do: a + b
      end
      """

      assert_clean(SingleClauseWith, code)
    end
  end

  describe "edge cases" do
    test "does not flag with having three <- clauses" do
      code = ~S"""
      defmodule MyApp.Pipeline do
        def run(input) do
          with {:ok, a} <- step1(input),
               {:ok, b} <- step2(a),
               {:ok, c} <- step3(b) do
            {:ok, c}
          end
        end

        defp step1(x), do: {:ok, x}
        defp step2(x), do: {:ok, x}
        defp step3(x), do: {:ok, x}
      end
      """

      assert_clean(SingleClauseWith, code)
    end

    test "handles with clause using bare pattern (= instead of <-)" do
      code = ~S"""
      defmodule MyApp.Config do
        def load do
          with {:ok, data} <- File.read("config.json") do
            Jason.decode(data)
          end
        end
      end
      """

      diagnostics = assert_flagged(SingleClauseWith, code)
      assert [_diag] = diagnostics
    end
  end
end
