defmodule Archdo.Rules.EventSourcing.AggregateMissingBehaviourTest do
  use Archdo.RuleCase

  alias Archdo.Rules.EventSourcing.AggregateMissingBehaviour

  describe "analyze/3" do
    test "flags aggregate shape without Commanded behaviour" do
      code = ~S"""
      defmodule MyApp.Account do
        defstruct [:id, :balance]

        def execute(%__MODULE__{}, %{type: :deposit}), do: %{type: :deposited}
        def apply(state, %{type: :deposited}), do: %{state | balance: 100}
      end
      """

      diags = assert_flagged(AggregateMissingBehaviour, code)
      assert hd(diags).rule_id == "8.8"
      assert hd(diags).message =~ "execute/2"
    end

    test "allows module with Commanded.Aggregates.Aggregate" do
      code = ~S"""
      defmodule MyApp.Account do
        use Commanded.Aggregates.Aggregate

        defstruct [:id, :balance]

        def execute(%__MODULE__{}, %{type: :deposit}), do: %{type: :deposited}
        def apply(state, %{type: :deposited}), do: %{state | balance: 100}
      end
      """

      assert_clean(AggregateMissingBehaviour, code)
    end

    test "ignores non-aggregate modules" do
      code = ~S"""
      defmodule MyApp.Calculator do
        def add(a, b), do: a + b
      end
      """

      assert_clean(AggregateMissingBehaviour, code)
    end
  end
end
