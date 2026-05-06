defmodule Archdo.Rules.Module.EmptyMapPatternMatchesAnyTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.EmptyMapPatternMatchesAny

  test "fires on `def f(%{})` — empty-map pattern matches ANY map, not just empty" do
    code = ~S"""
    defmodule MyApp.Classify do
      def empty?(%{}), do: true
      def empty?(_), do: false
    end
    """

    diags = assert_flagged(EmptyMapPatternMatchesAny, code)
    assert hd(diags).rule_id == "6.71"
    assert hd(diags).severity == :warning
    assert hd(diags).message =~ "matches ANY map"
  end

  test "does NOT fire on `def f(m) when map_size(m) == 0` (correct empty-map check)" do
    code = ~S"""
    defmodule MyApp.Classify do
      def empty?(m) when map_size(m) == 0, do: true
      def empty?(_), do: false
    end
    """

    assert_clean(EmptyMapPatternMatchesAny, code)
  end

  test "does NOT fire on `def f(%{key: v})` (non-empty map pattern with bindings)" do
    code = ~S"""
    defmodule MyApp.Get do
      def name(%{name: name}), do: name
    end
    """

    assert_clean(EmptyMapPatternMatchesAny, code)
  end
end
