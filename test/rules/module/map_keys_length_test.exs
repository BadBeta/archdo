defmodule Archdo.Rules.Module.MapKeysLengthTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.MapKeysLength

  describe "analyze/3" do
    test "flags Map.keys(m) |> length()" do
      code = ~S"""
      defmodule MyApp.Counter do
        def count_keys(map) do
          Map.keys(map) |> length()
        end
      end
      """

      diags = assert_flagged(MapKeysLength, code)
      diag = hd(diags)
      assert diag.rule_id == "6.48"
      assert diag.severity == :info
    end

    test "flags length(Map.keys(m))" do
      code = ~S"""
      defmodule MyApp.Counter do
        def count_keys(map) do
          length(Map.keys(map))
        end
      end
      """

      diags = assert_flagged(MapKeysLength, code)
      assert hd(diags).rule_id == "6.48"
    end

    test "flags Enum.count(Map.keys(m))" do
      code = ~S"""
      defmodule MyApp.Counter do
        def count_keys(map) do
          Enum.count(Map.keys(map))
        end
      end
      """

      diags = assert_flagged(MapKeysLength, code)
      assert hd(diags).rule_id == "6.48"
    end

    test "flags Map.values(m) |> length()" do
      code = ~S"""
      defmodule MyApp.Counter do
        def count_values(map) do
          Map.values(map) |> length()
        end
      end
      """

      diags = assert_flagged(MapKeysLength, code)
      assert hd(diags).rule_id == "6.48"
    end

    test "allows map_size(m)" do
      code = ~S"""
      defmodule MyApp.Counter do
        def count_keys(map) do
          map_size(map)
        end
      end
      """

      assert_clean(MapKeysLength, code)
    end

    test "allows Map.keys(m) used for actual key list" do
      code = ~S"""
      defmodule MyApp.Inspector do
        def get_keys(map) do
          Map.keys(map)
        end
      end
      """

      assert_clean(MapKeysLength, code)
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.CounterTest do
        def count(map) do
          Map.keys(map) |> length()
        end
      end
      """

      assert analyze(MapKeysLength, code, file: "test/counter_test.exs") == []
    end
  end
end
