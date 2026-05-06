defmodule Archdo.Rules.Module.NestedMapUpdateAsUpdateInTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.NestedMapUpdateAsUpdateIn

  describe "nested Map.update / Map.put" do
    test "flags Map.update with nested Map.put in the update fn" do
      code = ~S"""
      defmodule MyApp.Service do
        def bump(state) do
          Map.update(state, :counts, %{}, fn counts ->
            Map.put(counts, :total, 1)
          end)
        end
      end
      """

      [diag] = assert_flagged(NestedMapUpdateAsUpdateIn, code)
      assert diag.rule_id == "6.98"
      assert diag.severity == :info
      assert diag.message =~ "update_in"
    end

    test "flags Map.update with nested Map.update" do
      code = ~S"""
      defmodule MyApp.Tally do
        def add(state) do
          Map.update(state, :outer, %{}, fn outer ->
            Map.update(outer, :inner, 0, fn n -> n + 1 end)
          end)
        end
      end
      """

      [diag] = assert_flagged(NestedMapUpdateAsUpdateIn, code)
      assert diag.message =~ "update_in"
    end

    test "flags multiple instances in one module" do
      code = ~S"""
      defmodule MyApp.Service do
        def a(s), do: Map.update(s, :x, %{}, fn x -> Map.put(x, :y, 1) end)
        def b(s), do: Map.update(s, :p, %{}, fn p -> Map.put(p, :q, 2) end)
      end
      """

      diagnostics = assert_flagged(NestedMapUpdateAsUpdateIn, code)
      assert length(diagnostics) == 2
    end

    test "flags Map.update with capture-form update-fn (`&Map.put(&1, ...)`)" do
      code = ~S"""
      defmodule MyApp.RequestBuilder do
        def add_param(request, name, value) do
          Map.update(request, :body, %{name => value}, &Map.put(&1, name, value))
        end
      end
      """

      [diag] = assert_flagged(NestedMapUpdateAsUpdateIn, code)
      assert diag.message =~ "update_in"
    end

    test "flags Map.update! with capture-form update-fn" do
      code = ~S"""
      defmodule MyApp.Builder do
        def annotate(request, key, value) do
          Map.update!(request, :body, &Map.put(&1, key, value))
        end
      end
      """

      [_diag] = assert_flagged(NestedMapUpdateAsUpdateIn, code)
    end
  end

  describe "clean code" do
    test "does not flag a single-level Map.update" do
      code = ~S"""
      defmodule MyApp.Counter do
        def inc(state, key) do
          Map.update(state, key, 1, fn n -> n + 1 end)
        end
      end
      """

      assert_clean(NestedMapUpdateAsUpdateIn, code)
    end

    test "does not flag a single-level Map.put" do
      code = ~S"""
      defmodule MyApp.Set do
        def set(state, key, value) do
          Map.put(state, key, value)
        end
      end
      """

      assert_clean(NestedMapUpdateAsUpdateIn, code)
    end

    test "does not flag Map.update with non-map-update body" do
      code = ~S"""
      defmodule MyApp.Counter do
        def add(state, key, n) do
          Map.update(state, key, [n], fn xs -> [n | xs] end)
        end
      end
      """

      assert_clean(NestedMapUpdateAsUpdateIn, code)
    end

    test "does not flag update_in / put_in itself" do
      code = ~S"""
      defmodule MyApp.Lens do
        def deep(state) do
          update_in(state, [:a, :b], fn n -> n + 1 end)
        end
      end
      """

      assert_clean(NestedMapUpdateAsUpdateIn, code)
    end

    test "does not flag test files" do
      code = ~S"""
      defmodule MyApp.ServiceTest do
        def helper(s) do
          Map.update(s, :a, %{}, fn a -> Map.put(a, :b, 1) end)
        end
      end
      """

      assert_clean(NestedMapUpdateAsUpdateIn, code, file: "test/service_test.exs")
    end
  end

  describe "edge cases" do
    test "does not flag two sibling Map.update calls (not nested)" do
      code = ~S"""
      defmodule MyApp.Pipeline do
        def run(state) do
          state
          |> Map.update(:a, 1, &(&1 + 1))
          |> Map.update(:b, 1, &(&1 + 1))
        end
      end
      """

      assert_clean(NestedMapUpdateAsUpdateIn, code)
    end
  end

  describe "FP filter — different-structure inner call" do
    # Sequin-style: outer Map.put on `form_errors`, inner Map.put on `acc`
    # bound by Enum.reduce's lambda. Different structures → not a nested-update.
    test "does not flag Map.put with Enum.reduce in value-arg (different structure)" do
      code = ~S"""
      defmodule MyApp.FormErrors do
        def collect(form_errors, modified_test_messages) do
          Map.put(form_errors, :modified_test_messages,
            Enum.reduce(modified_test_messages, %{}, fn {trace_id, result}, acc ->
              case result do
                {:ok, _} -> acc
                %{error: errors} -> Map.put(acc, trace_id, errors)
              end
            end))
        end
      end
      """

      assert_clean(NestedMapUpdateAsUpdateIn, code)
    end

    # Map.update with Enum.reduce inside, where inner Map.put is on the reduce's
    # accumulator, NOT the lambda param. Different structures → not nested.
    test "does not flag Map.update whose lambda body is an Enum.reduce on a different acc" do
      code = ~S"""
      defmodule MyApp.Aggregator do
        def merge(state, batches) do
          Map.update(state, :totals, %{}, fn _existing ->
            Enum.reduce(batches, %{}, fn batch, acc -> Map.put(acc, batch.id, batch.total) end)
          end)
        end
      end
      """

      assert_clean(NestedMapUpdateAsUpdateIn, code)
    end

    # Map.put outer should NEVER flag — Map.put has no update-fn lambda, so any
    # nested Map.put in its value-arg is on a different structure by construction.
    test "does not flag Map.put outer with Map.put on Map.get of same key (no update-fn)" do
      code = ~S"""
      defmodule MyApp.Service do
        def deep_set(state) do
          Map.put(state, :a, Map.put(Map.get(state, :a, %{}), :b, 1))
        end
      end
      """

      assert_clean(NestedMapUpdateAsUpdateIn, code)
    end
  end
end
