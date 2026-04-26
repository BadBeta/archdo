defmodule Archdo.Rules.Module.KeywordLookupInLoopTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Module.KeywordLookupInLoop

  defp analyze(code) do
    {:ok, ast} =
      Code.string_to_quoted(code,
        columns: true,
        token_metadata: true,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    KeywordLookupInLoop.analyze("lib/example.ex", ast, [])
  end

  test "flags Keyword.get inside Enum.map" do
    diags =
      analyze("""
      defmodule Foo do
        def bar(items, opts) do
          Enum.map(items, fn item ->
            Keyword.get(opts, item)
          end)
        end
      end
      """)

    assert [%{title: "Keyword lookup inside loop"}] = diags
  end

  test "flags Keyword.fetch! inside Enum.reduce" do
    diags =
      analyze("""
      defmodule Foo do
        def bar(items, opts) do
          Enum.reduce(items, [], fn item, acc ->
            [Keyword.fetch!(opts, item) | acc]
          end)
        end
      end
      """)

    assert [%{title: "Keyword lookup inside loop"}] = diags
  end

  test "clean: Keyword.get outside loop is fine" do
    assert [] ==
             analyze("""
             defmodule Foo do
               def bar(opts), do: Keyword.get(opts, :key, :default)
             end
             """)
  end

  test "clean: Map.get inside loop is fine" do
    assert [] ==
             analyze("""
             defmodule Foo do
               def bar(items, map) do
                 Enum.map(items, fn item -> Map.get(map, item) end)
               end
             end
             """)
  end
end
