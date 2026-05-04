defmodule Archdo.AST.FunctionTest do
  use ExUnit.Case, async: true

  alias Archdo.AST.Function, as: AstFn

  defp parse(code) do
    {:ok, ast} = Code.string_to_quoted(code)
    ast
  end

  describe "extract_module_name/1" do
    test "returns the outer module name for nested defmodules" do
      ast = parse("""
      defmodule MyApp.Outer do
        defmodule Inner do
          defstruct [:x]
        end
      end
      """)

      assert "MyApp.Outer" = AstFn.extract_module_name(ast)
    end

    test "returns Unknown when no defmodule is present" do
      ast = parse("def f, do: 1")
      assert "Unknown" = AstFn.extract_module_name(ast)
    end
  end

  describe "extract_functions/2" do
    test "extracts all functions by default" do
      ast = parse("""
      defmodule M do
        def pub(x), do: x
        defp priv(x), do: x
      end
      """)

      names = AstFn.extract_functions(ast) |> Enum.map(&elem(&1, 0))
      assert :pub in names
      assert :priv in names
    end

    test "filters by visibility (:public)" do
      ast = parse("""
      defmodule M do
        def pub(x), do: x
        defp priv(x), do: x
      end
      """)

      names = AstFn.extract_functions(ast, :public) |> Enum.map(&elem(&1, 0))
      assert names == [:pub]
    end
  end

  describe "extract_callbacks/1" do
    test "groups GenServer callbacks by name" do
      ast = parse("""
      defmodule MyServer do
        def init(_), do: {:ok, %{}}
        def handle_call(:get, _from, state), do: {:reply, state, state}
      end
      """)

      cbs = AstFn.extract_callbacks(ast)
      assert is_list(cbs[:init])
      assert length(cbs[:init]) == 1
      assert length(cbs[:handle_call]) == 1
    end
  end

  describe "extract_test_name/1" do
    test "returns a bare-string test name" do
      assert "renders" = AstFn.extract_test_name(["renders", [do: nil]])
    end

    test "returns (unknown) for non-string names" do
      assert "(unknown)" = AstFn.extract_test_name([])
    end
  end

  describe "extract_test_blocks/1" do
    test "returns one tuple per test block" do
      ast = parse("""
      defmodule MyTest do
        use ExUnit.Case
        test "first", do: assert(true)
        test "second", do: assert(true)
      end
      """)

      blocks = AstFn.extract_test_blocks(ast)
      assert length(blocks) == 2
    end
  end
end
