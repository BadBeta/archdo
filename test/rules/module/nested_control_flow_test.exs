defmodule Archdo.Rules.Module.NestedControlFlowTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.NestedControlFlow

  describe "analyze/3" do
    test "flags with inside with" do
      code = ~S"""
      defmodule MyApp.Service do
        def create(params) do
          with {:ok, user} <- fetch_user(params) do
            with {:ok, account} <- create_account(user) do
              {:ok, account}
            end
          end
        end
      end
      """

      diags = assert_flagged(NestedControlFlow, code)
      assert hd(diags).rule_id == "6.44"
    end

    test "flags 3 levels of nested case" do
      code = ~S"""
      defmodule MyApp.Service do
        def process(data) do
          case validate(data) do
            {:ok, valid} ->
              case transform(valid) do
                {:ok, transformed} ->
                  case persist(transformed) do
                    {:ok, result} -> {:ok, result}
                    error -> error
                  end
                error -> error
              end
            error -> error
          end
        end
      end
      """

      diags = assert_flagged(NestedControlFlow, code)
      assert hd(diags).rule_id == "6.44"
    end

    test "allows 2 levels of nested case" do
      code = ~S"""
      defmodule MyApp.Service do
        def process(data) do
          case validate(data) do
            {:ok, valid} ->
              case transform(valid) do
                {:ok, result} -> {:ok, result}
                error -> error
              end
            error -> error
          end
        end
      end
      """

      assert_clean(NestedControlFlow, code)
    end

    test "allows flat with chain" do
      code = ~S"""
      defmodule MyApp.Service do
        def create(params) do
          with {:ok, user} <- fetch_user(params),
               {:ok, account} <- create_account(user) do
            {:ok, account}
          end
        end
      end
      """

      assert_clean(NestedControlFlow, code)
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.ServiceTest do
        def deeply_nested(x) do
          case x do
            :a ->
              case x do
                :b ->
                  case x do
                    :c -> :ok
                  end
              end
          end
        end
      end
      """

      assert_clean(NestedControlFlow, code, file: "test/my_app/service_test.exs")
    end
  end
end
