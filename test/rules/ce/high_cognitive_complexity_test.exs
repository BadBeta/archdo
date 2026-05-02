defmodule Archdo.Rules.CE.HighCognitiveComplexityTest do
  use Archdo.RuleCase

  alias Archdo.Rules.CE.HighCognitiveComplexity

  test "fires on function with cognitive complexity > 15" do
    # Build a deeply-nested body to push cognitive past 15.
    code = ~S"""
    defmodule MyApp.Tangled do
      def handle(x) do
        if x > 0 do
          case x do
            1 ->
              if x > 10 do
                case x do
                  10 -> :a
                  _ ->
                    cond do
                      x > 5 -> :b
                      x > 3 -> :c
                      true -> :d
                    end
                end
              else
                :small
              end
            _ -> :other
          end
        end
      end
    end
    """

    diags = assert_flagged(HighCognitiveComplexity, code, file: "lib/my_app/tangled.ex")
    assert hd(diags).rule_id == "CE-23"
    assert hd(diags).severity == :warning
    assert hd(diags).message =~ "handle"
  end

  test "does NOT fire on simple function" do
    code = ~S"""
    defmodule MyApp.Plain do
      def double(x), do: x * 2
    end
    """

    assert_clean(HighCognitiveComplexity, code, file: "lib/my_app/plain.ex")
  end

  test "does NOT fire on flat dispatch (multi-clause function with no nested logic)" do
    code = ~S"""
    defmodule MyApp.Dispatch do
      def handle(:a), do: 1
      def handle(:b), do: 2
      def handle(:c), do: 3
      def handle(:d), do: 4
      def handle(:e), do: 5
      def handle(:f), do: 6
      def handle(:g), do: 7
      def handle(:h), do: 8
      def handle(_), do: 0
    end
    """

    assert_clean(HighCognitiveComplexity, code, file: "lib/my_app/dispatch.ex")
  end
end
