defmodule Archdo.Rules.Module.TapOpportunityTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.TapOpportunity

  test "fires on `var = compute(); side_effect(var); var` — should be `compute() |> tap(&side_effect/1)`" do
    code = ~S"""
    defmodule MyApp.Order do
      def total(items) do
        result = Enum.sum(items)
        IO.inspect(result, label: "total")
        result
      end
    end
    """

    diags = assert_flagged(TapOpportunity, code)
    assert hd(diags).rule_id == "6.64"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "tap"
  end

  test "does NOT fire when the variable is transformed before being returned" do
    code = ~S"""
    defmodule MyApp.Order do
      def total(items) do
        result = Enum.sum(items)
        log(result)
        result + 1
      end

      defp log(_), do: :ok
    end
    """

    assert_clean(TapOpportunity, code)
  end

  test "does NOT fire when the variable isn't returned at the end" do
    code = ~S"""
    defmodule MyApp.Order do
      def store(items) do
        result = Enum.sum(items)
        save(result)
        :ok
      end

      defp save(_), do: :ok
    end
    """

    assert_clean(TapOpportunity, code)
  end
end
