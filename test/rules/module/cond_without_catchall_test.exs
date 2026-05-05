defmodule Archdo.Rules.Module.CondWithoutCatchallTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.CondWithoutCatchall

  test "fires on cond without a `true ->` catch-all clause" do
    code = ~S"""
    defmodule MyApp.Classify do
      def category(x) do
        cond do
          x > 10 -> :large
          x > 5 -> :medium
        end
      end
    end
    """

    diags = assert_flagged(CondWithoutCatchall, code)
    assert hd(diags).rule_id == "6.61"
    assert hd(diags).severity == :warning
    assert hd(diags).message =~ "CondClauseError"
  end

  test "does NOT fire when cond has an explicit `true ->` catch-all" do
    code = ~S"""
    defmodule MyApp.Classify do
      def category(x) do
        cond do
          x > 10 -> :large
          x > 5 -> :medium
          true -> :small
        end
      end
    end
    """

    assert_clean(CondWithoutCatchall, code)
  end

  test "does NOT fire on `cond` whose final clause is a non-`true` constant guaranteed to match (e.g., :otherwise via convention)" do
    # Some codebases use `:else` or other always-truthy conventions.
    # The rule's contract is specifically about `true` — anything else
    # is the developer's responsibility to verify.
    code = ~S"""
    defmodule MyApp.Classify do
      def category(x) do
        cond do
          x > 10 -> :large
          :otherwise -> :small
        end
      end
    end
    """

    assert_clean(CondWithoutCatchall, code)
  end
end
