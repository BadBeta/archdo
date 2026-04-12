defmodule Archdo.Rules.StateMachine.StateReachabilityTest do
  use Archdo.RuleCase

  alias Archdo.Rules.StateMachine.StateReachability

  test "flags unreachable states in fsmx transition map" do
    code = ~S"""
    defmodule MyApp.Order do
      def transitions do
        %{
          "pending" => ["confirmed", "cancelled"],
          "confirmed" => ["shipped"],
          "shipped" => ["delivered"],
          "orphaned" => ["pending"]
        }
      end
    end
    """

    diags = assert_flagged(StateReachability, code)
    assert Enum.any?(diags, &(&1.message =~ "orphaned"))
  end

  test "allows fully reachable state machine" do
    code = ~S"""
    defmodule MyApp.Order do
      def transitions do
        %{
          "pending" => ["confirmed", "cancelled"],
          "confirmed" => ["shipped"],
          "shipped" => ["delivered"]
        }
      end
    end
    """

    assert_clean(StateReachability, code)
  end
end
