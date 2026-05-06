defmodule Archdo.Rules.Module.JasonDecodeWithAtomKeysTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.JasonDecodeWithAtomKeys

  test "fires on `Jason.decode!(json, keys: :atoms)`" do
    code = ~S"""
    defmodule MyApp.Api do
      def parse(body), do: Jason.decode!(body, keys: :atoms)
    end
    """

    diags = assert_flagged(JasonDecodeWithAtomKeys, code)
    assert hd(diags).rule_id == "6.84"
    assert hd(diags).severity == :warning
    assert hd(diags).message =~ "atom table"
  end

  test "fires on `Jason.decode(body, keys: :atoms)` (non-bang variant)" do
    code = ~S"""
    defmodule MyApp.Api do
      def parse(body), do: Jason.decode(body, keys: :atoms)
    end
    """

    diags = assert_flagged(JasonDecodeWithAtomKeys, code)
    assert hd(diags).rule_id == "6.84"
  end

  test "does NOT fire on `Jason.decode!(body, keys: :atoms!)` (existing-only)" do
    code = ~S"""
    defmodule MyApp.Api do
      def parse(body), do: Jason.decode!(body, keys: :atoms!)
    end
    """

    assert_clean(JasonDecodeWithAtomKeys, code)
  end

  test "does NOT fire on `Jason.decode!(body)` (default string keys)" do
    code = ~S"""
    defmodule MyApp.Api do
      def parse(body), do: Jason.decode!(body)
    end
    """

    assert_clean(JasonDecodeWithAtomKeys, code)
  end
end
