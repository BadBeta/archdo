defmodule Archdo.Rules.Module.IdentityTransformationTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Module.IdentityTransformation

  defp analyze(code) do
    {:ok, ast} =
      Code.string_to_quoted(code,
        columns: true,
        token_metadata: true,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    IdentityTransformation.analyze("lib/example.ex", ast, [])
  end

  describe "identity map" do
    test "flags Enum.map with fn x -> x end" do
      diagnostics =
        analyze("""
        defmodule Foo do
          def bar(list) do
            Enum.map(list, fn x -> x end)
          end
        end
        """)

      assert [%{message: msg}] = diagnostics
      assert msg =~ "Enum.map"
      assert msg =~ "no-op"
    end

    test "flags Enum.map with & &1" do
      diagnostics =
        analyze("""
        defmodule Foo do
          def bar(list) do
            Enum.map(list, & &1)
          end
        end
        """)

      assert [%{message: msg}] = diagnostics
      assert msg =~ "Enum.map"
    end

    test "clean: Enum.map with actual transformation is fine" do
      diagnostics =
        analyze("""
        defmodule Foo do
          def bar(list) do
            Enum.map(list, fn x -> x + 1 end)
          end
        end
        """)

      assert diagnostics == []
    end

    test "clean: Enum.map with function capture is fine" do
      diagnostics =
        analyze("""
        defmodule Foo do
          def bar(list) do
            Enum.map(list, &String.upcase/1)
          end
        end
        """)

      assert diagnostics == []
    end
  end

  describe "always-true filter" do
    test "flags Enum.filter with fn _ -> true end" do
      diagnostics =
        analyze("""
        defmodule Foo do
          def bar(list) do
            Enum.filter(list, fn _ -> true end)
          end
        end
        """)

      assert [%{message: msg}] = diagnostics
      assert msg =~ "Enum.filter"
      assert msg =~ "no-op"
    end

    test "clean: Enum.filter with actual predicate is fine" do
      diagnostics =
        analyze("""
        defmodule Foo do
          def bar(list) do
            Enum.filter(list, fn x -> x > 0 end)
          end
        end
        """)

      assert diagnostics == []
    end
  end

  describe "always-false reject" do
    test "flags Enum.reject with fn _ -> false end" do
      diagnostics =
        analyze("""
        defmodule Foo do
          def bar(list) do
            Enum.reject(list, fn _ -> false end)
          end
        end
        """)

      assert [%{message: msg}] = diagnostics
      assert msg =~ "Enum.reject"
      assert msg =~ "no-op"
    end

    test "clean: Enum.reject with actual predicate is fine" do
      diagnostics =
        analyze("""
        defmodule Foo do
          def bar(list) do
            Enum.reject(list, fn x -> x == 0 end)
          end
        end
        """)

      assert diagnostics == []
    end
  end

  describe "flatten single element" do
    test "flags List.flatten([single])" do
      diagnostics =
        analyze("""
        defmodule Foo do
          def bar(x) do
            List.flatten([x])
          end
        end
        """)

      assert [%{message: msg}] = diagnostics
      assert msg =~ "List.flatten"
      assert msg =~ "redundant"
    end

    test "clean: List.flatten with multiple elements is fine" do
      diagnostics =
        analyze("""
        defmodule Foo do
          def bar(x, y) do
            List.flatten([x, y])
          end
        end
        """)

      assert diagnostics == []
    end

    test "clean: List.flatten on a variable is fine" do
      diagnostics =
        analyze("""
        defmodule Foo do
          def bar(list) do
            List.flatten(list)
          end
        end
        """)

      assert diagnostics == []
    end
  end

  describe "test file skipping" do
    test "skips test files" do
      {:ok, ast} =
        Code.string_to_quoted(
          """
          defmodule FooTest do
            def bar(list), do: Enum.map(list, fn x -> x end)
          end
          """,
          columns: true,
          token_metadata: true,
          literal_encoder: &{:ok, {:__block__, &2, [&1]}}
        )

      assert IdentityTransformation.analyze("test/foo_test.exs", ast, []) == []
    end
  end
end
