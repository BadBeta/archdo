defmodule Archdo.Rules.Boundary.UmbrellaDepConsistencyTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Boundary.UmbrellaDepConsistency

  defp analyze(code) do
    {:ok, ast} =
      Code.string_to_quoted(code,
        columns: true,
        token_metadata: true,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    UmbrellaDepConsistency.analyze("apps/my_app/mix.exs", ast, [])
  end

  test "flags in_umbrella: true with runtime: false but no only:" do
    diags =
      analyze("""
      defmodule MyApp.MixProject do
        defp deps do
          [
            {:shared_types, in_umbrella: true, runtime: false}
          ]
        end
      end
      """)

    assert [%{message: msg}] = diags
    assert msg =~ ":shared_types"
    assert msg =~ "in_umbrella: true, runtime: false"
  end

  test "clean: in_umbrella with only: is fine" do
    assert [] ==
             analyze("""
             defmodule MyApp.MixProject do
               defp deps do
                 [
                   {:test_support, in_umbrella: true, only: :test, runtime: false}
                 ]
               end
             end
             """)
  end

  test "clean: in_umbrella without runtime: false is fine" do
    assert [] ==
             analyze("""
             defmodule MyApp.MixProject do
               defp deps do
                 [
                   {:core, in_umbrella: true}
                 ]
               end
             end
             """)
  end

  test "skips non-mix.exs files" do
    {:ok, ast} =
      Code.string_to_quoted(
        """
        defmodule Foo do
          defp deps do
            [{:shared, in_umbrella: true, runtime: false}]
          end
        end
        """,
        columns: true,
        token_metadata: true,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    assert [] == UmbrellaDepConsistency.analyze("lib/foo.ex", ast, [])
  end
end
