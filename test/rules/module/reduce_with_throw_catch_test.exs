defmodule Archdo.Rules.Module.ReduceWithThrowCatchTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.ReduceWithThrowCatch

  test "fires on Enum.reduce wrapped in try/catch with throw inside the reducer" do
    code = ~S"""
    defmodule MyApp.Search do
      def find_first(items, pred) do
        try do
          Enum.reduce(items, nil, fn item, _acc ->
            cond do
              pred.(item) -> throw({:found, item})
              true -> nil
            end
          end)
        catch
          {:found, item} -> item
        end
      end
    end
    """

    diags = assert_flagged(ReduceWithThrowCatch, code)
    assert hd(diags).rule_id == "6.60"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "reduce_while"
  end

  test "does NOT fire on Enum.reduce_while (already idiomatic)" do
    code = ~S"""
    defmodule MyApp.Search do
      def find_first(items, pred) do
        Enum.reduce_while(items, nil, fn item, acc ->
          case pred.(item) do
            true -> {:halt, item}
            false -> {:cont, acc}
          end
        end)
      end
    end
    """

    assert_clean(ReduceWithThrowCatch, code)
  end

  test "does NOT fire on Enum.reduce without throw inside" do
    code = ~S"""
    defmodule MyApp.Sum do
      def total(items), do: Enum.reduce(items, 0, &(&1 + &2))
    end
    """

    assert_clean(ReduceWithThrowCatch, code)
  end
end
