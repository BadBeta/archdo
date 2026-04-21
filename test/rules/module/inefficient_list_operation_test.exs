defmodule Archdo.Rules.Module.InefficientListOperationTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.InefficientListOperation

  describe "list ++ [item] (pattern 1)" do
    test "flags list ++ [single_item] append" do
      code = ~S"""
      defmodule MyApp.Builder do
        def build(items) do
          Enum.reduce(items, [], fn item, acc ->
            acc ++ [item]
          end)
        end
      end
      """

      diags = assert_flagged(InefficientListOperation, code)
      diag = hd(diags)
      assert diag.rule_id == "6.50"
      assert diag.severity == :warning
      assert diag.title =~ "append via ++"
    end

    test "does not flag ++ with multi-element right side" do
      code = ~S"""
      defmodule MyApp.Merger do
        def merge(a, b) do
          a ++ b
        end
      end
      """

      assert_clean(InefficientListOperation, code)
    end
  end

  describe "Enum.at(list, 0) (pattern 2)" do
    test "flags Enum.at(list, 0)" do
      code = ~S"""
      defmodule MyApp.Fetcher do
        def first(list) do
          Enum.at(list, 0)
        end
      end
      """

      diags = assert_flagged(InefficientListOperation, code)
      diag = hd(diags)
      assert diag.rule_id == "6.50"
      assert diag.severity == :info
      assert diag.title =~ "Enum.at(list, 0)"
    end
  end

  describe "List.last in loop (pattern 3)" do
    test "flags List.last inside Enum.map callback" do
      code = ~S"""
      defmodule MyApp.Processor do
        def process(lists) do
          Enum.map(lists, fn list ->
            List.last(list)
          end)
        end
      end
      """

      diags = assert_flagged(InefficientListOperation, code)
      assert hd(diags).title =~ "List.last"
    end

    test "does not flag standalone List.last outside loop" do
      code = ~S"""
      defmodule MyApp.Util do
        def last_item(list) do
          List.last(list)
        end
      end
      """

      assert_clean(InefficientListOperation, code)
    end

    test "flags List.last inside for comprehension" do
      code = ~S"""
      defmodule MyApp.Comp do
        def lasts(lists) do
          for list <- lists, do: List.last(list)
        end
      end
      """

      diags = assert_flagged(InefficientListOperation, code)
      assert hd(diags).title =~ "List.last"
    end
  end

  describe "Enum.reverse |> hd (pattern 4)" do
    test "flags Enum.reverse(list) |> hd()" do
      code = ~S"""
      defmodule MyApp.Last do
        def last_elem(list) do
          Enum.reverse(list) |> hd()
        end
      end
      """

      diags = assert_flagged(InefficientListOperation, code)
      assert hd(diags).title =~ "reverse"
    end

    test "flags hd(Enum.reverse(list))" do
      code = ~S"""
      defmodule MyApp.Last do
        def last_elem(list) do
          hd(Enum.reverse(list))
        end
      end
      """

      diags = assert_flagged(InefficientListOperation, code)
      assert hd(diags).title =~ "reverse"
    end
  end

  describe "List.insert_at(list, -1, item) (pattern 5)" do
    test "flags List.insert_at with -1 index" do
      code = ~S"""
      defmodule MyApp.Appender do
        def append(list, item) do
          List.insert_at(list, -1, item)
        end
      end
      """

      diags = assert_flagged(InefficientListOperation, code)
      diag = hd(diags)
      assert diag.severity == :warning
      assert diag.title =~ "insert_at"
    end

    test "does not flag List.insert_at with index 0" do
      code = ~S"""
      defmodule MyApp.Prepender do
        def prepend(list, item) do
          List.insert_at(list, 0, item)
        end
      end
      """

      assert_clean(InefficientListOperation, code)
    end
  end

  describe "List.delete_at in loop (pattern 6)" do
    test "flags List.delete_at inside Enum.reduce callback" do
      code = ~S"""
      defmodule MyApp.Cleaner do
        def remove_indices(list, indices) do
          Enum.reduce(indices, list, fn idx, acc ->
            List.delete_at(acc, idx)
          end)
        end
      end
      """

      diags = assert_flagged(InefficientListOperation, code)
      assert hd(diags).title =~ "delete_at"
    end

    test "does not flag standalone List.delete_at outside loop" do
      code = ~S"""
      defmodule MyApp.Util do
        def remove_first(list) do
          List.delete_at(list, 0)
        end
      end
      """

      assert_clean(InefficientListOperation, code)
    end
  end

  describe "Enum.at with variable index in loop (pattern 7)" do
    test "flags Enum.at(list, idx) inside Enum.each callback" do
      code = ~S"""
      defmodule MyApp.Accessor do
        def access_all(list, indices) do
          Enum.each(indices, fn idx ->
            IO.inspect(Enum.at(list, idx))
          end)
        end
      end
      """

      diags = assert_flagged(InefficientListOperation, code)
      assert hd(diags).title =~ "variable index"
    end

    test "does not flag Enum.at with variable index outside loop" do
      code = ~S"""
      defmodule MyApp.Util do
        def get_item(list, idx) do
          Enum.at(list, idx)
        end
      end
      """

      assert_clean(InefficientListOperation, code)
    end
  end

  describe "test file skipping" do
    test "skips test files" do
      code = ~S"""
      defmodule MyApp.BuilderTest do
        def build(items) do
          acc ++ [items]
        end
      end
      """

      assert analyze(InefficientListOperation, code, file: "test/builder_test.exs") == []
    end
  end

  describe "clean code" do
    test "allows idiomatic prepend and reverse" do
      code = ~S"""
      defmodule MyApp.Builder do
        def build(items) do
          items
          |> Enum.reduce([], fn item, acc -> [item | acc] end)
          |> Enum.reverse()
        end
      end
      """

      assert_clean(InefficientListOperation, code)
    end

    test "allows hd/1 for first element" do
      code = ~S"""
      defmodule MyApp.Fetcher do
        def first(list) do
          hd(list)
        end
      end
      """

      assert_clean(InefficientListOperation, code)
    end
  end
end
