defmodule Archdo.Rules.Boundary.DevDepInProdTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Boundary.DevDepInProd

  defp analyze(code) do
    {:ok, ast} = Code.string_to_quoted(code, columns: true, token_metadata: true,
      literal_encoder: &{:ok, {:__block__, &2, [&1]}})
    DevDepInProd.analyze("mix.exs", ast, [])
  end

  test "flags :credo without only:" do
    diags = analyze("""
    defmodule MyApp.MixProject do
      defp deps do
        [
          {:credo, "~> 1.7"}
        ]
      end
    end
    """)

    assert [%{message: msg}] = diags
    assert msg =~ ":credo"
    assert msg =~ "no `only:`"
  end

  test "flags :dialyxir without only:" do
    diags = analyze("""
    defmodule MyApp.MixProject do
      defp deps do
        [
          {:dialyxir, "~> 1.4"}
        ]
      end
    end
    """)

    assert [%{message: msg}] = diags
    assert msg =~ ":dialyxir"
  end

  test "clean: :credo with only: is fine" do
    assert [] == analyze("""
    defmodule MyApp.MixProject do
      defp deps do
        [
          {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
        ]
      end
    end
    """)
  end

  test "clean: production dep without only: is fine" do
    assert [] == analyze("""
    defmodule MyApp.MixProject do
      defp deps do
        [
          {:jason, "~> 1.4"},
          {:phoenix, "~> 1.7"}
        ]
      end
    end
    """)
  end

  test "skips non-mix.exs files" do
    {:ok, ast} = Code.string_to_quoted("""
    defmodule Foo do
      defp deps do
        [{:credo, "~> 1.7"}]
      end
    end
    """, columns: true, token_metadata: true,
      literal_encoder: &{:ok, {:__block__, &2, [&1]}})

    assert [] == DevDepInProd.analyze("lib/foo.ex", ast, [])
  end

  test "flags multiple dev deps" do
    diags = analyze("""
    defmodule MyApp.MixProject do
      defp deps do
        [
          {:jason, "~> 1.4"},
          {:credo, "~> 1.7"},
          {:ex_doc, "~> 0.30"},
          {:mox, "~> 1.0"}
        ]
      end
    end
    """)

    names = Enum.map(diags, fn d -> d.message end)
    assert length(diags) == 3
    assert Enum.any?(names, &String.contains?(&1, ":credo"))
    assert Enum.any?(names, &String.contains?(&1, ":ex_doc"))
    assert Enum.any?(names, &String.contains?(&1, ":mox"))
  end
end
