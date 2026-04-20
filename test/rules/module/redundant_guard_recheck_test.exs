defmodule Archdo.Rules.Module.RedundantGuardRecheckTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Module.RedundantGuardRecheck

  defp analyze(code) do
    {:ok, ast} =
      Code.string_to_quoted(code,
        columns: true,
        token_metadata: true,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    RedundantGuardRecheck.analyze("lib/example.ex", ast, [])
  end

  describe "pattern match guarantees" do
    test "flags is_map when param matched as %{} = var" do
      diagnostics = analyze("""
      defmodule Foo do
        def process(%{} = x) do
          if is_map(x), do: :yes, else: :no
        end
      end
      """)

      assert [%{message: msg}] = diagnostics
      assert msg =~ "is_map"
      assert msg =~ "redundant"
    end

    test "flags is_list when param matched as [_ | _] = var" do
      diagnostics = analyze("""
      defmodule Foo do
        def process([_ | _] = items) do
          if is_list(items), do: length(items), else: 0
        end
      end
      """)

      assert [%{message: msg}] = diagnostics
      assert msg =~ "is_list"
      assert msg =~ "redundant"
    end

    test "flags is_binary when param matched as <<>> = var" do
      diagnostics = analyze("""
      defmodule Foo do
        def process(<<>> = data) do
          if is_binary(data), do: byte_size(data), else: 0
        end
      end
      """)

      assert [%{message: msg}] = diagnostics
      assert msg =~ "is_binary"
      assert msg =~ "redundant"
    end

    test "clean: is_map on unmatched variable is fine" do
      diagnostics = analyze("""
      defmodule Foo do
        def process(x) do
          if is_map(x), do: :map, else: :other
        end
      end
      """)

      assert diagnostics == []
    end

    test "clean: different type check is fine" do
      diagnostics = analyze("""
      defmodule Foo do
        def process(%{} = x) do
          if is_list(x), do: :list, else: :not_list
        end
      end
      """)

      assert diagnostics == []
    end
  end

  describe "guard clause guarantees" do
    test "flags is_list in body when guard already checks is_list" do
      diagnostics = analyze("""
      defmodule Foo do
        def process(x) when is_list(x) do
          if is_list(x), do: length(x), else: 0
        end
      end
      """)

      assert [%{message: msg}] = diagnostics
      assert msg =~ "is_list"
      assert msg =~ "redundant"
    end

    test "flags is_map in body when guard already checks is_map" do
      diagnostics = analyze("""
      defmodule Foo do
        def process(x) when is_map(x) do
          case is_map(x) do
            true -> Map.keys(x)
            false -> []
          end
        end
      end
      """)

      assert [%{message: msg}] = diagnostics
      assert msg =~ "is_map"
    end

    test "clean: guard checks different variable than body check" do
      diagnostics = analyze("""
      defmodule Foo do
        def process(x, y) when is_list(x) do
          if is_list(y), do: y, else: []
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
            def process(%{} = x), do: is_map(x)
          end
          """,
          columns: true,
          token_metadata: true,
          literal_encoder: &{:ok, {:__block__, &2, [&1]}}
        )

      assert RedundantGuardRecheck.analyze("test/foo_test.exs", ast, []) == []
    end
  end
end
