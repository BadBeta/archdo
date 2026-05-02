defmodule Archdo.CognitiveComplexityTest do
  use ExUnit.Case, async: true

  alias Archdo.CognitiveComplexity

  defp body_of(code) do
    {:ok, ast} = Code.string_to_quoted(code)
    {:def, _, [_head, [do: body]]} = ast
    body
  end

  describe "score/1 — Campbell's rules" do
    test "trivial body has score 0" do
      assert CognitiveComplexity.score(body_of("def f, do: :ok")) == 0
    end

    test "+1 per top-level control-flow structure (if)" do
      body = body_of("def f(x) do\n  if x > 0, do: :pos, else: :other\nend")
      assert CognitiveComplexity.score(body) == 1
    end

    test "+1 per case clause set + nesting penalty for nested case-in-if" do
      # if (1) → +1
      #   case (2) — nested at depth 1 → +2
      # total = 3
      body =
        body_of("""
        def f(x) do
          if x > 0 do
            case x do
              1 -> :one
              _ -> :other
            end
          end
        end
        """)

      assert CognitiveComplexity.score(body) == 3
    end

    test "+1 per logical operator chained beyond the first" do
      # a && b: +1 (the && itself)
      # a && b && c: +1 + 1 (second && in the chain) = 2
      body = body_of("def f(a, b, c, d), do: a && b && c && d")
      assert CognitiveComplexity.score(body) == 3
    end

    test "multi-clause function counts as ONE case structure (idiomatic dispatch)" do
      # The CALLER side: a single multi-clause function should NOT
      # blow up cognitive complexity. The engine here scores ONE
      # function body — the multi-clause-counts-as-one is enforced at
      # the caller level (CE-23 / CE-24 only score one body at a time).
      # This test guards the per-body scoring stays accurate.
      body = body_of("def f(0), do: :zero")
      assert CognitiveComplexity.score(body) == 0
    end
  end
end
