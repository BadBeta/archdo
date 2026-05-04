defmodule Archdo.Rules.Composition.PipelineShapeMismatchTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Composition.PipelineShapeMismatch

  defp parse(code, file) do
    {:ok, ast} =
      Code.string_to_quoted(code,
        file: file,
        columns: true,
        token_metadata: true
      )

    {file, ast}
  end

  defp analyze(file_asts), do: PipelineShapeMismatch.analyze_project(file_asts)

  describe "fires when a producer's tuple output is a permutation of a consumer's input" do
    test "producer returns {atom, integer}, consumer expects (integer, atom)" do
      file_asts = [
        parse(
          """
          defmodule MyApp.Producer do
            @spec emit() :: {atom(), integer()}
            def emit, do: {:ok, 1}
          end
          """,
          "lib/my_app/producer.ex"
        ),
        parse(
          """
          defmodule MyApp.Consumer do
            @spec take(integer(), atom()) :: :ok
            def take(_n, _tag), do: :ok
          end
          """,
          "lib/my_app/consumer.ex"
        )
      ]

      diags = analyze(file_asts)
      assert length(diags) >= 1
      assert hd(diags).rule_id == "10.5"
      assert hd(diags).severity == :info
    end
  end

  describe "does NOT fire" do
    test "producer's tuple output matches consumer's input order" do
      file_asts = [
        parse(
          """
          defmodule MyApp.Producer do
            @spec emit() :: {integer(), atom()}
            def emit, do: {1, :ok}
          end
          """,
          "lib/my_app/producer.ex"
        ),
        parse(
          """
          defmodule MyApp.Consumer do
            @spec take(integer(), atom()) :: :ok
            def take(_n, _tag), do: :ok
          end
          """,
          "lib/my_app/consumer.ex"
        )
      ]

      assert analyze(file_asts) == []
    end

    test "no consumer accepts the producer's tuple shape" do
      file_asts = [
        parse(
          """
          defmodule MyApp.Producer do
            @spec emit() :: {atom(), integer()}
            def emit, do: {:ok, 1}
          end
          """,
          "lib/my_app/producer.ex"
        ),
        parse(
          """
          defmodule MyApp.Other do
            @spec other(String.t()) :: :ok
            def other(_), do: :ok
          end
          """,
          "lib/my_app/other.ex"
        )
      ]

      assert analyze(file_asts) == []
    end

    test "consumer takes a single tuple parameter (no decomposition)" do
      file_asts = [
        parse(
          """
          defmodule MyApp.Producer do
            @spec emit() :: {atom(), integer()}
            def emit, do: {:ok, 1}
          end
          """,
          "lib/my_app/producer.ex"
        ),
        parse(
          """
          defmodule MyApp.Consumer do
            @spec take({atom(), integer()}) :: :ok
            def take(_pair), do: :ok
          end
          """,
          "lib/my_app/consumer.ex"
        )
      ]

      assert analyze(file_asts) == []
    end

    test "test files are excluded" do
      file_asts = [
        parse(
          """
          defmodule MyApp.ProducerTest do
            @spec emit() :: {atom(), integer()}
            def emit, do: {:ok, 1}
          end
          """,
          "test/my_app/producer_test.exs"
        ),
        parse(
          """
          defmodule MyApp.ConsumerTest do
            @spec take(integer(), atom()) :: :ok
            def take(_n, _tag), do: :ok
          end
          """,
          "test/my_app/consumer_test.exs"
        )
      ]

      assert analyze(file_asts) == []
    end

    test "matching multiset but identical order should not flag" do
      # Producer returns (integer, atom); consumer takes (integer, atom).
      # No permutation — pipeline already works.
      file_asts = [
        parse(
          """
          defmodule MyApp.Producer do
            @spec emit() :: {integer(), atom()}
            def emit, do: {1, :ok}
          end
          """,
          "lib/my_app/producer.ex"
        ),
        parse(
          """
          defmodule MyApp.Consumer do
            @spec take(integer(), atom()) :: :ok
            def take(_n, _tag), do: :ok
          end
          """,
          "lib/my_app/consumer.ex"
        )
      ]

      assert analyze(file_asts) == []
    end
  end

  describe "arity-3 mismatch" do
    test "producer returns {a,b,c}, consumer expects (b,c,a)" do
      file_asts = [
        parse(
          """
          defmodule MyApp.Producer do
            @spec emit() :: {integer(), atom(), String.t()}
            def emit, do: {1, :ok, ""}
          end
          """,
          "lib/my_app/producer.ex"
        ),
        parse(
          """
          defmodule MyApp.Consumer do
            @spec take(atom(), String.t(), integer()) :: :ok
            def take(_a, _b, _c), do: :ok
          end
          """,
          "lib/my_app/consumer.ex"
        )
      ]

      diags = analyze(file_asts)
      assert length(diags) >= 1
      assert hd(diags).rule_id == "10.5"
    end
  end
end
