defmodule Archdo.Rules.StateMachine.IncompleteStateMatchTest do
  use Archdo.RuleCase

  alias Archdo.Rules.StateMachine.IncompleteStateMatch

  test "fires when case-on-state misses declared states without catch-all" do
    code = ~S"""
    defmodule MyApp.Order do
      @states [:pending, :paid, :shipped, :refunded]

      def label(state) do
        case state do
          :pending -> "waiting"
          :paid -> "received"
        end
      end
    end
    """

    diags = assert_flagged(IncompleteStateMatch, code)
    assert hd(diags).rule_id == "SM-F"
    assert hd(diags).severity == :warning
    assert hd(diags).message =~ ":shipped"
    assert hd(diags).message =~ ":refunded"
  end

  test "does NOT fire when all declared states are matched" do
    code = ~S"""
    defmodule MyApp.Order do
      @states [:pending, :paid]

      def label(state) do
        case state do
          :pending -> "waiting"
          :paid -> "received"
        end
      end
    end
    """

    assert_clean(IncompleteStateMatch, code)
  end

  test "does NOT fire when a catch-all clause is present" do
    code = ~S"""
    defmodule MyApp.Order do
      @states [:pending, :paid, :shipped, :refunded]

      def label(state) do
        case state do
          :pending -> "waiting"
          :paid -> "received"
          _ -> "later state"
        end
      end
    end
    """

    assert_clean(IncompleteStateMatch, code)
  end

  test "does NOT fire when no @states declaration exists" do
    code = ~S"""
    defmodule MyApp.Free do
      def label(s), do: case s do
        :a -> 1
        :b -> 2
      end
    end
    """

    assert_clean(IncompleteStateMatch, code)
  end
end
