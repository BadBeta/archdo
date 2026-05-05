defmodule Archdo.Stats.HalsteadTest do
  use ExUnit.Case, async: true

  alias Archdo.Stats.Halstead

  defp body_of(code) do
    {:ok, ast} = Code.string_to_quoted(code)
    {:def, _, [_head, [do: body]]} = ast
    body
  end

  describe "analyze_function/1 — operator and operand classification" do
    test "operator-light pure function has low volume and effort" do
      # body: x * 2  →  operators: [:*]; operands: [x, 2]
      # vocabulary = 1 + 2 = 3, length = 1 + 2 = 3
      # volume = 3 * log2(3) ≈ 4.75 — small number
      result = Halstead.analyze_function(body_of("def double(x), do: x * 2"))

      assert result.total_operators == 1
      assert result.total_operands == 2
      assert result.volume < 10.0
      assert result.effort < 20.0
    end

    test "branch-heavy function has higher difficulty than a single-expression function" do
      simple = Halstead.analyze_function(body_of("def f(x), do: x + 1"))

      branchy =
        Halstead.analyze_function(
          body_of("""
          def f(x) do
            case x do
              1 -> :one
              2 -> :two
              3 -> :three
              4 -> :four
              5 -> :five
            end
          end
          """)
        )

      assert branchy.difficulty > simple.difficulty
      assert branchy.effort > simple.effort
    end

    test "operands count includes literals and variables" do
      # body: x + 1 + y + 2  →  operands: x, 1, y, 2  (4 distinct)
      result = Halstead.analyze_function(body_of("def f(x, y), do: x + 1 + y + 2"))

      assert result.distinct_operands == 4
      assert result.total_operands == 4
    end

    test "operators count chained pipes" do
      # body: x |> g() |> h() |> i()  →  3 pipe operator instances
      result = Halstead.analyze_function(body_of("def f(x), do: x |> g() |> h() |> i()"))

      assert result.total_operators == 3
    end

    test "vocabulary equals distinct_operators + distinct_operands" do
      # body: x + y + x  →  operators: {:+ × 2}; operands: {x × 2, y × 1}
      # distinct_ops = 1, distinct_opnds = 2, vocabulary = 3
      result = Halstead.analyze_function(body_of("def f(x, y), do: x + y + x"))

      assert result.distinct_operators == 1
      assert result.distinct_operands == 2
      assert result.vocabulary == result.distinct_operators + result.distinct_operands
      assert result.vocabulary == 3
    end

    test "length equals total_operators + total_operands" do
      # Same fixture as the vocabulary test —  total_ops = 2, total_opnds = 3
      result = Halstead.analyze_function(body_of("def f(x, y), do: x + y + x"))

      assert result.total_operators == 2
      assert result.total_operands == 3
      assert result.length == result.total_operators + result.total_operands
      assert result.length == 5
    end
  end

  describe "analyze/1 — module-level rollup" do
    test "module rolls up totals across all public functions" do
      code = """
      defmodule M do
        def f(x), do: x + 1
        def g(x), do: x * 2
      end
      """

      {:ok, ast} = Code.string_to_quoted(code)
      module_h = Halstead.analyze(ast)

      # f body: + (1 op), x (1 opnd), 1 (1 opnd) → ops=1, opnds=2
      # g body: * (1 op), x (1 opnd), 2 (1 opnd) → ops=1, opnds=2
      # rollup: total_ops = 2, total_opnds = 4
      assert module_h.total_operators == 2
      assert module_h.total_operands == 4
    end
  end
end
