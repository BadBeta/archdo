defmodule Archdo.Rules.StateMachine.UndeclaredNextStateTest do
  use Archdo.RuleCase

  alias Archdo.Rules.StateMachine.UndeclaredNextState

  test "fires when {:next_state, X, ...} returns X not in @states" do
    code = ~S"""
    defmodule MyApp.Door do
      @states [:closed, :open, :locked]
      def transition(:closed, :open_door), do: {:next_state, :openn, %{}}
    end
    """

    diags = assert_flagged(UndeclaredNextState, code)
    assert hd(diags).rule_id == "SM-A"
    assert hd(diags).severity == :warning
    assert hd(diags).message =~ ":openn"
  end

  test "does NOT fire when X is in @states" do
    code = ~S"""
    defmodule MyApp.Door do
      @states [:closed, :open, :locked]
      def transition(:closed, :open_door), do: {:next_state, :open, %{}}
      def transition(:open, :close_door), do: {:next_state, :closed, %{}}
    end
    """

    assert_clean(UndeclaredNextState, code)
  end

  test "does NOT fire when no @states declaration exists (rule is opt-in)" do
    code = ~S"""
    defmodule MyApp.UnDeclared do
      def transition(_), do: {:next_state, :anything, %{}}
    end
    """

    assert_clean(UndeclaredNextState, code)
  end

  test "fires once per distinct undeclared target across multiple transitions" do
    code = ~S"""
    defmodule MyApp.Door do
      @states [:closed, :open]
      def t1(_), do: {:next_state, :half_open, %{}}
      def t2(_), do: {:next_state, :half_open, %{}}
      def t3(_), do: {:next_state, :slammed, %{}}
    end
    """

    diags = assert_flagged(UndeclaredNextState, code)
    assert length(diags) == 3
  end
end
