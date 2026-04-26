defmodule Archdo.Rules.Module.VerboseOkUnwrapTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Module.VerboseOkUnwrap

  defp analyze(code) do
    {:ok, ast} =
      Code.string_to_quoted(code,
        columns: true,
        token_metadata: true,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    VerboseOkUnwrap.analyze("lib/example.ex", ast, [])
  end

  describe "swallow error, return nil" do
    test "flags case with {:ok, val} -> val; {:error, _} -> nil" do
      diagnostics =
        analyze("""
        defmodule Foo do
          def bar(id) do
            case fetch(id) do
              {:ok, val} -> val
              {:error, _} -> nil
            end
          end
        end
        """)

      assert [%{title: title}] = diagnostics
      assert title =~ "swallow error"
    end

    test "clean: case with {:ok, val} -> val; {:error, reason} -> {:error, reason} is fine" do
      diagnostics =
        analyze("""
        defmodule Foo do
          def bar(id) do
            case fetch(id) do
              {:ok, val} -> val
              {:error, reason} -> {:error, reason}
            end
          end
        end
        """)

      assert diagnostics == []
    end

    test "clean: case with different ok handling is fine" do
      diagnostics =
        analyze("""
        defmodule Foo do
          def bar(id) do
            case fetch(id) do
              {:ok, val} -> process(val)
              {:error, _} -> nil
            end
          end
        end
        """)

      assert diagnostics == []
    end
  end

  describe "single ok clause" do
    test "flags case with only {:ok, val} -> val" do
      diagnostics =
        analyze("""
        defmodule Foo do
          def bar(id) do
            case fetch(id) do
              {:ok, val} -> val
            end
          end
        end
        """)

      assert [%{title: title}] = diagnostics
      assert title =~ "only :ok clause"
    end

    test "clean: case with multiple clauses is fine" do
      diagnostics =
        analyze("""
        defmodule Foo do
          def bar(id) do
            case fetch(id) do
              {:ok, val} -> val
              {:error, :not_found} -> default()
              {:error, reason} -> raise reason
            end
          end
        end
        """)

      assert diagnostics == []
    end

    test "clean: single clause that transforms value is fine" do
      diagnostics =
        analyze("""
        defmodule Foo do
          def bar(id) do
            case fetch(id) do
              {:ok, val} -> process(val)
            end
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
            def bar(id) do
              case fetch(id) do
                {:ok, val} -> val
                {:error, _} -> nil
              end
            end
          end
          """,
          columns: true,
          token_metadata: true,
          literal_encoder: &{:ok, {:__block__, &2, [&1]}}
        )

      assert VerboseOkUnwrap.analyze("test/foo_test.exs", ast, []) == []
    end
  end
end
