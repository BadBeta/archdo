defmodule Archdo.Rules.Module.PredicateMissingQuestionMarkTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.PredicateMissingQuestionMark

  describe "analyze/3" do
    test "flags function returning literal true/false in different clauses" do
      code = ~S"""
      defmodule MyApp.Validator do
        def is_admin(%{role: :admin}), do: true
        def is_admin(_), do: false
      end
      """

      diags =
        assert_flagged(PredicateMissingQuestionMark, code, file: "lib/my_app/validator.ex")

      assert hd(diags).rule_id == "6.88"
    end

    test "flags single-clause function returning a guard expression" do
      code = ~S"""
      defmodule MyApp.Check do
        def has_email(%{email: e}) when is_binary(e) and byte_size(e) > 0, do: true
        def has_email(_), do: false
      end
      """

      assert_flagged(PredicateMissingQuestionMark, code, file: "lib/my_app/check.ex")
    end

    test "ignores function whose name ends in ?" do
      code = ~S"""
      defmodule MyApp.Validator do
        def admin?(%{role: :admin}), do: true
        def admin?(_), do: false
      end
      """

      assert_clean(PredicateMissingQuestionMark, code, file: "lib/my_app/validator.ex")
    end

    test "ignores function returning non-boolean values" do
      code = ~S"""
      defmodule MyApp.Calc do
        def total(%{amount: a}), do: a * 2
        def total(_), do: 0
      end
      """

      assert_clean(PredicateMissingQuestionMark, code, file: "lib/my_app/calc.ex")
    end

    test "ignores function returning a single literal (not boolean dispatch)" do
      code = ~S"""
      defmodule MyApp.Const do
        def threshold, do: 100
      end
      """

      assert_clean(PredicateMissingQuestionMark, code, file: "lib/my_app/const.ex")
    end

    test "ignores predicate functions that are private (defp)" do
      code = ~S"""
      defmodule MyApp.Internal do
        defp is_locked(%{locked: l}), do: l == true
        defp is_locked(_), do: false
      end
      """

      assert_clean(PredicateMissingQuestionMark, code, file: "lib/my_app/internal.ex")
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.ValidatorTest do
        def is_match(%{a: 1}), do: true
        def is_match(_), do: false
      end
      """

      assert_clean(PredicateMissingQuestionMark, code, file: "test/validator_test.exs")
    end
  end
end
