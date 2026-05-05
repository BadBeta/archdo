defmodule Archdo.Rules.Module.CallbackHellTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.CallbackHell

  test "fires on 4-deep nested anonymous functions" do
    code = ~S"""
    defmodule MyApp.Worker do
      def go(items) do
        Enum.map(items, fn x ->
          Enum.map(x, fn y ->
            Enum.map(y, fn z ->
              Enum.map(z, fn w -> w + 1 end)
            end)
          end)
        end)
      end
    end
    """

    diags = assert_flagged(CallbackHell, code)
    assert hd(diags).rule_id == "6.59"
    assert hd(diags).severity == :info
  end

  test "does NOT fire at exactly 3 nested anonymous functions (at threshold)" do
    code = ~S"""
    defmodule MyApp.Worker do
      def go(items) do
        Enum.map(items, fn x ->
          Enum.map(x, fn y ->
            Enum.map(y, fn z -> z + 1 end)
          end)
        end)
      end
    end
    """

    assert_clean(CallbackHell, code)
  end

  test "does NOT fire on a flat pipeline of multiple anonymous functions (each top-level)" do
    code = ~S"""
    defmodule MyApp.Pipeline do
      def transform(list) do
        list
        |> Enum.map(fn x -> x + 1 end)
        |> Enum.filter(fn x -> x > 0 end)
        |> Enum.map(fn x -> x * 2 end)
        |> Enum.reduce(0, fn x, acc -> acc + x end)
        |> tap(fn total -> IO.puts(total) end)
      end
    end
    """

    assert_clean(CallbackHell, code)
  end
end
