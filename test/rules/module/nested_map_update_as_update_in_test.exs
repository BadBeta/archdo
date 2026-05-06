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

    test "flags Map.put with nested Map.put (3 levels deep)" do
      code = ~S"""
      defmodule MyApp.Service do
        def deep_set(state) do
          Map.put(state, :a, Map.put(Map.get(state, :a, %{}), :b, 1))
        end
      end
      """

      [diag] = assert_flagged(NestedMapUpdateAsUpdateIn, code)
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
end
