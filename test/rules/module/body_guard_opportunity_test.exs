defmodule Archdo.Rules.Module.BodyGuardOpportunityTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.BodyGuardOpportunity

  test "fires on `def f(x), do: unless is_integer(x), do: raise ...; ...` — head guard would express the same constraint" do
    code = ~S"""
    defmodule MyApp.Validate do
      def double(x) do
        unless is_integer(x), do: raise(ArgumentError, "expected integer")
        x * 2
      end
    end
    """

    diags = assert_flagged(BodyGuardOpportunity, code)
    assert hd(diags).rule_id == "6.77"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "guard"
  end

  test "does NOT fire on `def f(x) when is_integer(x), do: x * 2` (already a head guard)" do
    code = ~S"""
    defmodule MyApp.Validate do
      def double(x) when is_integer(x), do: x * 2
    end
    """

    assert_clean(BodyGuardOpportunity, code)
  end

  test "does NOT fire on body validation that's NOT a guard predicate" do
    code = ~S"""
    defmodule MyApp.Validate do
      def double(x) do
        if x > 1_000_000, do: raise(ArgumentError, "too large")
        x * 2
      end
    end
    """

    # The check `x > 1_000_000` could be a guard, but the rule's
    # narrow scope is on `is_*` type-predicates that are unambiguous
    # head-guard fits. Range guards are deferred (they may legitimately
    # belong in the body for variable thresholds).
    assert_clean(BodyGuardOpportunity, code)
  end
end
