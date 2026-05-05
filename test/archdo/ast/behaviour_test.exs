defmodule Archdo.AST.BehaviourTest do
  use ExUnit.Case, async: true

  alias Archdo.AST.Behaviour, as: AstBehaviour

  defp parse(code) do
    {:ok, ast} = Code.string_to_quoted(code)
    ast
  end

  describe "collect_callbacks/1" do
    test "collects {name, arity} pairs for each @callback in a behaviour module" do
      ast =
        parse("""
        defmodule MyApp.Cache do
          @callback get(key :: term()) :: term() | nil
          @callback put(key :: term(), value :: term()) :: :ok
        end
        """)

      result = AstBehaviour.collect_callbacks([{"lib/cache.ex", ast}])
      assert MapSet.member?(result["MyApp.Cache"], {:get, 1})
      assert MapSet.member?(result["MyApp.Cache"], {:put, 2})
    end

    test "skips modules without @callback declarations" do
      ast =
        parse("""
        defmodule MyApp.Plain do
          def f(x), do: x
        end
        """)

      assert AstBehaviour.collect_callbacks([{"lib/plain.ex", ast}]) == %{}
    end

    test "merges callbacks from multiple behaviour modules" do
      a = parse("defmodule MyApp.A do\n  @callback foo() :: :ok\nend")
      b = parse("defmodule MyApp.B do\n  @callback bar(integer()) :: integer()\nend")

      result = AstBehaviour.collect_callbacks([{"a.ex", a}, {"b.ex", b}])
      assert Map.has_key?(result, "MyApp.A")
      assert Map.has_key?(result, "MyApp.B")
    end
  end

  describe "implemented_callbacks/2" do
    test "returns empty for a module without @behaviour declarations" do
      ast = parse("defmodule MyApp.Plain do\n  def f(x), do: x\nend")
      assert MapSet.size(AstBehaviour.implemented_callbacks(ast, %{})) == 0
    end

    test "resolves @behaviour Foo to Foo's callback set" do
      ast =
        parse("""
        defmodule MyApp.Logger do
          @behaviour MyApp.Middleware
          def before_dispatch(p), do: p
        end
        """)

      callbacks_map = %{
        "MyApp.Middleware" => MapSet.new([{:before_dispatch, 1}, {:after_dispatch, 1}])
      }

      result = AstBehaviour.implemented_callbacks(ast, callbacks_map)
      assert MapSet.member?(result, {:before_dispatch, 1})
      assert MapSet.member?(result, {:after_dispatch, 1})
    end

    test "returns empty when behaviour is unknown to the project (e.g. GenServer)" do
      ast =
        parse("""
        defmodule MyApp.Worker do
          @behaviour GenServer
          def init(_), do: {:ok, %{}}
        end
        """)

      assert MapSet.size(AstBehaviour.implemented_callbacks(ast, %{})) == 0
    end

    test "unions callbacks from multiple @behaviour declarations" do
      ast =
        parse("""
        defmodule MyApp.Combo do
          @behaviour MyApp.A
          @behaviour MyApp.B
        end
        """)

      callbacks_map = %{
        "MyApp.A" => MapSet.new([{:foo, 0}]),
        "MyApp.B" => MapSet.new([{:bar, 0}])
      }

      result = AstBehaviour.implemented_callbacks(ast, callbacks_map)
      assert MapSet.member?(result, {:foo, 0})
      assert MapSet.member?(result, {:bar, 0})
    end
  end
end
