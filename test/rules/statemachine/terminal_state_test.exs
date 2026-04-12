defmodule Archdo.Rules.StateMachine.TerminalStateIntegrityTest do
  use Archdo.RuleCase

  alias Archdo.Rules.StateMachine.TerminalStateIntegrity

  test "flags terminal state with outgoing transitions" do
    code = ~S"""
    defmodule MyApp.Order do
      def transitions do
        %{
          "pending" => ["confirmed"],
          "confirmed" => ["completed"],
          "completed" => ["pending"]
        }
      end
    end
    """

    diags = assert_flagged(TerminalStateIntegrity, code)
    assert hd(diags).message =~ "completed"
  end

  test "allows proper terminal state" do
    code = ~S"""
    defmodule MyApp.Order do
      def transitions do
        %{
          "pending" => ["confirmed", "cancelled"],
          "confirmed" => ["completed"]
        }
      end
    end
    """

    assert_clean(TerminalStateIntegrity, code)
  end
end
