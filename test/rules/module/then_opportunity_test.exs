defmodule Archdo.Rules.Module.ThenOpportunityTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.ThenOpportunity

  test "fires on `data |> (fn x -> some_fn(x, extra) end).()` — should be `then(&some_fn(&1, extra))`" do
    code = ~S"""
    defmodule MyApp.Pipeline do
      def transform(data, extra) do
        data
        |> normalize()
        |> (fn x -> compute(x, extra) end).()
      end

      defp normalize(d), do: d
      defp compute(_, _), do: :ok
    end
    """

    diags = assert_flagged(ThenOpportunity, code)
    assert hd(diags).rule_id == "6.63"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "then("
  end

  test "does NOT fire on `then/2` (already idiomatic)" do
    code = ~S"""
    defmodule MyApp.Pipeline do
      def transform(data, extra) do
        data
        |> normalize()
        |> then(&compute(&1, extra))
      end

      defp normalize(d), do: d
      defp compute(_, _), do: :ok
    end
    """

    assert_clean(ThenOpportunity, code)
  end

  test "does NOT fire on a normal anonymous function inside Enum.map (not a pipeline-style invocation)" do
    code = ~S"""
    defmodule MyApp.Pipeline do
      def transform(list) do
        Enum.map(list, fn x -> x * 2 end)
      end
    end
    """

    assert_clean(ThenOpportunity, code)
  end
end
