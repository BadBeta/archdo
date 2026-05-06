defmodule Archdo.Rules.Module.RepeatedGuardChainTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.RepeatedGuardChain

  test "fires when 2+ function heads share the same compound guard chain" do
    code = ~S"""
    defmodule MyApp.Validator do
      def positive?(n) when is_integer(n) and n > 0 and n < 100, do: true
      def positive?(_), do: false

      def normalize(n) when is_integer(n) and n > 0 and n < 100, do: n
      def normalize(_), do: 0
    end
    """

    diags = assert_flagged(RepeatedGuardChain, code)
    assert hd(diags).rule_id == "6.73"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "defguard"
  end

  test "does NOT fire when each head has a unique guard" do
    code = ~S"""
    defmodule MyApp.Mixed do
      def f(x) when is_integer(x) and x > 0, do: x
      def g(x) when is_binary(x) and byte_size(x) > 0, do: x
    end
    """

    assert_clean(RepeatedGuardChain, code)
  end

  test "does NOT fire on a single-head function with a guard" do
    code = ~S"""
    defmodule MyApp.Simple do
      def f(x) when is_integer(x) and x > 0, do: x
    end
    """

    assert_clean(RepeatedGuardChain, code)
  end
end
