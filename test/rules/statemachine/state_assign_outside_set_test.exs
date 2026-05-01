defmodule Archdo.Rules.StateMachine.StateAssignOutsideSetTest do
  use Archdo.RuleCase

  alias Archdo.Rules.StateMachine.StateAssignOutsideSet

  test "fires on `state: :unknown` map literal when :unknown not in @states" do
    code = ~S"""
    defmodule MyApp.Order do
      @states [:pending, :paid, :shipped]
      def reset(order), do: %{order | state: :spuninglobinvented}
    end
    """

    diags = assert_flagged(StateAssignOutsideSet, code)
    assert hd(diags).rule_id == "SM-D"
    assert hd(diags).severity == :warning
    assert hd(diags).message =~ ":spuninglobinvented"
  end

  test "does NOT fire when assigned state is in @states" do
    code = ~S"""
    defmodule MyApp.Order do
      @states [:pending, :paid, :shipped]
      def mark_paid(order), do: %{order | state: :paid}
    end
    """

    assert_clean(StateAssignOutsideSet, code)
  end

  test "does NOT fire when no @states declaration exists" do
    code = ~S"""
    defmodule MyApp.Free do
      def x(o), do: %{o | state: :anything}
    end
    """

    assert_clean(StateAssignOutsideSet, code)
  end

  test "does NOT fire when value is dynamic (variable) — that's SM-E (unverifiable)" do
    code = ~S"""
    defmodule MyApp.Order do
      @states [:pending, :paid]
      def transition(order, new_state), do: %{order | state: new_state}
    end
    """

    assert_clean(StateAssignOutsideSet, code)
  end
end
