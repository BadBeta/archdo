defmodule Archdo.Rules.Module.CodeSlopTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Module.CodeSlop

  defp analyze(code) do
    {:ok, ast} =
      Code.string_to_quoted(code,
        columns: true,
        token_metadata: true,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    CodeSlop.analyze("lib/example.ex", ast, [])
  end

  describe "@doc on private functions" do
    test "flags @doc before defp" do
      diagnostics =
        analyze("""
        defmodule Foo do
          @doc "Does a thing"
          defp thing(x), do: x + 1
        end
        """)

      assert [%{message: msg}] = diagnostics
      assert msg =~ "@doc before defp thing"
    end

    test "clean: @doc before def is fine" do
      diagnostics =
        analyze("""
        defmodule Foo do
          @doc "Does a thing"
          def thing(x), do: x + 1
        end
        """)

      assert diagnostics == []
    end
  end

  describe "trivial delegation wrappers" do
    test "flags defp that just delegates with same name and args" do
      diagnostics =
        analyze("""
        defmodule Foo do
          defp bar(x, y), do: Baz.bar(x, y)
        end
        """)

      assert [%{message: msg}] = diagnostics
      assert msg =~ "bar/2 just delegates"
      assert msg =~ "Baz.bar"
    end

    test "clean: different function name is not flagged" do
      diagnostics =
        analyze("""
        defmodule Foo do
          defp do_thing(x), do: Helper.process(x)
        end
        """)

      assert diagnostics == []
    end

    test "clean: wrapper with different arity is not flagged" do
      diagnostics =
        analyze("""
        defmodule Foo do
          defp bar(x), do: Baz.bar(x, :default)
        end
        """)

      assert diagnostics == []
    end

    test "clean: wrapper with transformation is not flagged" do
      diagnostics =
        analyze("""
        defmodule Foo do
          defp bar(x), do: Baz.bar(String.trim(x))
        end
        """)

      assert diagnostics == []
    end
  end

  describe "redundant boolean comparisons" do
    test "flags == true" do
      diagnostics =
        analyze("""
        defmodule Foo do
          def check(x) do
            if x == true, do: :yes, else: :no
          end
        end
        """)

      assert [%{message: msg}] = diagnostics
      assert msg =~ "== true"
    end

    test "flags == false" do
      diagnostics =
        analyze("""
        defmodule Foo do
          def check(x) do
            if x == false, do: :yes, else: :no
          end
        end
        """)

      assert [%{message: msg}] = diagnostics
      assert msg =~ "== false"
    end

    test "flags != true" do
      diagnostics =
        analyze("""
        defmodule Foo do
          def check(x) do
            if x != true, do: :yes, else: :no
          end
        end
        """)

      assert [%{message: msg}] = diagnostics
      assert msg =~ "!= true"
    end

    test "clean: comparing to non-boolean is fine" do
      diagnostics =
        analyze("""
        defmodule Foo do
          def check(x) do
            if x == :active, do: :yes, else: :no
          end
        end
        """)

      assert diagnostics == []
    end
  end

  describe "empty @doc" do
    test "flags @doc with empty string" do
      diagnostics =
        analyze("""
        defmodule Foo do
          @doc ""
          def thing, do: :ok
        end
        """)

      assert [%{message: msg}] = diagnostics
      assert msg =~ "empty string"
    end

    test "flags @moduledoc with empty string" do
      diagnostics =
        analyze("""
        defmodule Foo do
          @moduledoc ""
          def thing, do: :ok
        end
        """)

      assert [%{message: msg}] = diagnostics
      assert msg =~ "@moduledoc"
    end

    test "clean: @doc false is fine" do
      diagnostics =
        analyze("""
        defmodule Foo do
          @doc false
          def thing, do: :ok
        end
        """)

      assert diagnostics == []
    end

    test "clean: @moduledoc false is fine" do
      diagnostics =
        analyze("""
        defmodule Foo do
          @moduledoc false
          def thing, do: :ok
        end
        """)

      assert diagnostics == []
    end
  end

  describe "single-step pipeline" do
    test "flags single pipe" do
      diagnostics =
        analyze("""
        defmodule Foo do
          def bar(list) do
            list |> Enum.sort()
          end
        end
        """)

      assert [%{message: msg}] = diagnostics
      assert msg =~ "Single"
    end

    test "clean: multi-step pipeline is fine" do
      diagnostics =
        analyze("""
        defmodule Foo do
          def bar(list) do
            list
            |> Enum.sort()
            |> Enum.uniq()
          end
        end
        """)

      assert diagnostics == []
    end

    test "clean: no pipe is fine" do
      diagnostics =
        analyze("""
        defmodule Foo do
          def bar(list) do
            Enum.sort(list)
          end
        end
        """)

      assert diagnostics == []
    end
  end
end
