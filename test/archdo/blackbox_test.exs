defmodule Archdo.BlackboxTest do
  use ExUnit.Case, async: true

  alias Archdo.Blackbox

  defp parse_def(code) do
    {:ok, ast} = Code.string_to_quoted(code)
    ast
  end

  defp possibility(code) do
    code
    |> parse_def()
    |> Blackbox.possibility()
  end

  describe "possibility/1 — per-component scoring" do
    test "trivial pure function scores 1.0 (all components present)" do
      ast =
        parse_def("""
        defmodule M do
          @spec double(integer()) :: integer()
          def double(x), do: x * 2
        end
        """)

      [{_name, _arity, score, _components}] = Blackbox.score_module(ast)
      assert score == 1.0
    end

    test "Application.get_env in body lowers input-closure score" do
      ast =
        parse_def("""
        defmodule M do
          @spec ttl() :: integer()
          def ttl, do: Application.get_env(:my_app, :ttl)
        end
        """)

      [{_, _, score, components}] = Blackbox.score_module(ast)
      assert components.input_closure < 1.0
      assert score < 1.0
    end

    test "DateTime.utc_now in body forces determinism to 0" do
      ast =
        parse_def("""
        defmodule M do
          @spec stamp() :: DateTime.t()
          def stamp, do: DateTime.utc_now()
        end
        """)

      [{_, _, score, components}] = Blackbox.score_module(ast)
      assert components.determinism == 0.0
      assert score == 0.0
    end

    test "Logger.info in body forces side-effect-freedom to 0" do
      ast =
        parse_def("""
        defmodule M do
          @spec log(String.t()) :: :ok
          def log(msg) do
            Logger.info(msg)
            :ok
          end
        end
        """)

      [{_, _, score, components}] = Blackbox.score_module(ast)
      assert components.side_effect_free == 0.0
      assert score == 0.0
    end

    test "raise in body forces errors-as-values to 0 (non-bang function)" do
      ast =
        parse_def("""
        defmodule M do
          @spec validate(integer()) :: :ok
          def validate(x) when x < 0, do: raise(ArgumentError, "negative")
          def validate(_), do: :ok
        end
        """)

      # Multi-clause function — each clause is scored independently.
      # The clause with raise has errors_as_values 0.
      results = Blackbox.score_module(ast)
      raising_clause = Enum.find(results, fn {_, _, _, c} -> c.errors_as_values == 0.0 end)
      assert raising_clause != nil
      {_, _, score, _} = raising_clause
      assert score == 0.0
    end

    test "missing @spec drops output_completeness to 0.0" do
      ast =
        parse_def("""
        defmodule M do
          def double(x), do: x * 2
        end
        """)

      [{_, _, _score, components}] = Blackbox.score_module(ast)
      assert components.output_completeness == 0.0
    end
  end

  describe "classify/1" do
    test "≥ 0.9 → :building_block" do
      assert Blackbox.classify(1.0) == :building_block
      assert Blackbox.classify(0.95) == :building_block
    end

    test "0.7–0.9 → :near_block" do
      assert Blackbox.classify(0.8) == :near_block
      assert Blackbox.classify(0.7) == :near_block
    end

    test "0.4–0.7 → :mixed" do
      assert Blackbox.classify(0.5) == :mixed
    end

    test "< 0.4 → :boundary" do
      assert Blackbox.classify(0.0) == :boundary
      assert Blackbox.classify(0.39) == :boundary
    end
  end
end
