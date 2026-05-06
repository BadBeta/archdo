defmodule Archdo.Rules.Module.EnumIntoMapAsMapNewTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.EnumIntoMapAsMapNew

  describe "analyze/3" do
    test "flags Enum.into(coll, %{})" do
      code = ~S"""
      defmodule MyApp.Build do
        def index(pairs) do
          Enum.into(pairs, %{})
        end
      end
      """

      diags = assert_flagged(EnumIntoMapAsMapNew, code, file: "lib/my_app/build.ex")
      assert hd(diags).rule_id == "6.91"
    end

    test "flags Enum.into(coll, %{}, fun)" do
      code = ~S"""
      defmodule MyApp.Build do
        def index(rows) do
          Enum.into(rows, %{}, fn row -> {row.id, row.name} end)
        end
      end
      """

      assert_flagged(EnumIntoMapAsMapNew, code, file: "lib/my_app/build.ex")
    end

    test "ignores Enum.into into a non-empty map" do
      code = ~S"""
      defmodule MyApp.Build do
        def index(pairs, base) do
          Enum.into(pairs, base)
        end
      end
      """

      assert_clean(EnumIntoMapAsMapNew, code, file: "lib/my_app/build.ex")
    end

    test "ignores Enum.into into a list / MapSet" do
      code = ~S"""
      defmodule MyApp.Build do
        def to_list(pairs), do: Enum.into(pairs, [])
        def to_set(pairs), do: Enum.into(pairs, MapSet.new())
      end
      """

      assert_clean(EnumIntoMapAsMapNew, code, file: "lib/my_app/build.ex")
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.BuildTest do
        def fixture(pairs), do: Enum.into(pairs, %{})
      end
      """

      assert_clean(EnumIntoMapAsMapNew, code, file: "test/build_test.exs")
    end
  end
end
