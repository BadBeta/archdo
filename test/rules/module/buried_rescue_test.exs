defmodule Archdo.Rules.Module.BuriedRescueTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.BuriedRescue

  describe "try/rescue inside anonymous function" do
    test "flags try/rescue buried in fn callback" do
      code = ~S"""
      defmodule MyApp.Processor do
        def process_all(items) do
          Enum.map(items, fn item ->
            try do
              transform(item)
            rescue
              _ -> nil
            end
          end)
        end

        defp transform(item), do: item
      end
      """

      diagnostics = assert_flagged(BuriedRescue, code)
      assert [diag] = diagnostics
      assert diag.rule_id == "6.32"
      assert diag.message =~ "Enum.map callback"
    end

    test "flags try/rescue inside Enum.flat_map callback" do
      code = ~S"""
      defmodule MyApp.Loader do
        def load_all(paths) do
          Enum.flat_map(paths, fn path ->
            try do
              [File.read!(path)]
            rescue
              _ -> []
            end
          end)
        end
      end
      """

      [diag] = assert_flagged(BuriedRescue, code)
      assert diag.message =~ "Enum.flat_map"
    end
  end

  describe "clean code — no false positives" do
    test "does not flag try/rescue in named private function" do
      code = ~S"""
      defmodule MyApp.Safe do
        def process(items) do
          Enum.map(items, &safe_transform/1)
        end

        defp safe_transform(item) do
          try do
            transform(item)
          rescue
            _ -> nil
          end
        end

        defp transform(item), do: item
      end
      """

      assert_clean(BuriedRescue, code)
    end

    test "does not flag try/after (cleanup pattern)" do
      code = ~S"""
      defmodule MyApp.Cleanup do
        def with_resource(fun) do
          resource = acquire()
          try do
            fun.(resource)
          after
            release(resource)
          end
        end

        defp acquire, do: :resource
        defp release(_), do: :ok
      end
      """

      assert_clean(BuriedRescue, code)
    end

    test "does not flag test files" do
      code = ~S"""
      defmodule MyApp.ProcessorTest do
        def helper(items) do
          Enum.map(items, fn item ->
            try do
              transform(item)
            rescue
              _ -> nil
            end
          end)
        end

        defp transform(item), do: item
      end
      """

      assert_clean(BuriedRescue, code, file: "test/processor_test.exs")
    end
  end
end
