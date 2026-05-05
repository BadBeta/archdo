defmodule Archdo.Rules.Module.PipesOnOneLineTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.PipesOnOneLine

  test "fires when 2+ pipe operators appear on a single source line" do
    code = ~S"""
    defmodule MyApp.Format do
      def transform(list), do: list |> Enum.map(&format/1) |> Enum.join(", ")

      defp format(x), do: to_string(x)
    end
    """

    diags = assert_flagged(PipesOnOneLine, code)
    assert hd(diags).rule_id == "6.62"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "one pipe per line"
  end

  test "does NOT fire when each pipe is on its own line" do
    code = ~S"""
    defmodule MyApp.Format do
      def transform(list) do
        list
        |> Enum.map(&format/1)
        |> Enum.join(", ")
      end

      defp format(x), do: to_string(x)
    end
    """

    assert_clean(PipesOnOneLine, code)
  end

  test "does NOT fire on a single pipe (covered by 6.33 single-step pipeline)" do
    code = ~S"""
    defmodule MyApp.Format do
      def upcase_one(name), do: name |> String.upcase()
    end
    """

    assert_clean(PipesOnOneLine, code)
  end
end
