defmodule Archdo.Rules.Module.ZipMapAsZipWithTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.ZipMapAsZipWith

  test "fires on `Enum.zip(a, b) |> Enum.map(fn {x, y} -> f.(x, y) end)`" do
    code = ~S"""
    defmodule MyApp.Pair do
      def combine(xs, ys) do
        Enum.zip(xs, ys) |> Enum.map(fn {x, y} -> x + y end)
      end
    end
    """

    diags = assert_flagged(ZipMapAsZipWith, code)
    assert hd(diags).rule_id == "6.65"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "zip_with"
  end

  test "does NOT fire on Enum.zip_with (already idiomatic)" do
    code = ~S"""
    defmodule MyApp.Pair do
      def combine(xs, ys), do: Enum.zip_with(xs, ys, fn x, y -> x + y end)
    end
    """

    assert_clean(ZipMapAsZipWith, code)
  end

  test "does NOT fire on Enum.zip alone (not piped to map)" do
    code = ~S"""
    defmodule MyApp.Pair do
      def pair(xs, ys), do: Enum.zip(xs, ys)
    end
    """

    assert_clean(ZipMapAsZipWith, code)
  end
end
