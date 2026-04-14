defmodule Archdo.ASTTest do
  use ExUnit.Case, async: true

  alias Archdo.AST

  describe "parse_file/1" do
    test "parses a valid Elixir file" do
      path = Path.join(System.tmp_dir!(), "ast_test_#{:rand.uniform(100_000)}.ex")
      File.write!(path, "defmodule Foo do\n  def bar, do: :ok\nend")

      try do
        assert {:ok, ast} = AST.parse_file(path)
        assert is_tuple(ast)
      after
        File.rm(path)
      end
    end

    test "returns error for missing file" do
      assert {:error, msg} = AST.parse_file("missing_#{:rand.uniform(100_000)}.ex")
      assert is_binary(msg)
    end

    test "returns error for invalid syntax" do
      path = Path.join(System.tmp_dir!(), "ast_bad_#{:rand.uniform(100_000)}.ex")
      File.write!(path, "defmodule Foo do\n  def bar(\nend")

      try do
        assert {:error, _} = AST.parse_file(path)
      after
        File.rm(path)
      end
    end
  end

  describe "extract_module_name/1" do
    test "extracts module name from defmodule" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule MyApp.Workers.Processor do
          def run, do: :ok
        end
        """)

      assert AST.extract_module_name(ast) == "MyApp.Workers.Processor"
    end

    test "returns Unknown for non-module code" do
      {:ok, ast} = Code.string_to_quoted("1 + 2")
      assert AST.extract_module_name(ast) == "Unknown"
    end
  end

  describe "extract_functions/2" do
    test "extracts public functions" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule Foo do
          def public_one(x), do: x
          def public_two(a, b), do: a + b
          defp private_one(x), do: x * 2
        end
        """)

      fns = AST.extract_functions(ast, :public)
      names = Enum.map(fns, fn {name, _arity, _meta, _args, _body} -> name end)
      assert :public_one in names
      assert :public_two in names
      refute :private_one in names
    end

    test "extracts all functions with :all" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule Foo do
          def pub(x), do: x
          defp priv(x), do: x
        end
        """)

      fns = AST.extract_functions(ast, :all)
      names = Enum.map(fns, fn {name, _, _, _, _} -> name end)
      assert :pub in names
      assert :priv in names
    end
  end

  describe "genserver_module?/1" do
    test "returns true for module with use GenServer" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule MyServer do
          use GenServer
        end
        """)

      assert AST.genserver_module?(ast)
    end

    test "returns true for module with GenServer callbacks" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule MyServer do
          def handle_call(:ping, _from, state), do: {:reply, :pong, state}
        end
        """)

      assert AST.genserver_module?(ast)
    end

    test "returns false for plain module" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule MyModule do
          def hello, do: :world
        end
        """)

      refute AST.genserver_module?(ast)
    end
  end

  describe "test_file?/1" do
    test "returns true for test files" do
      assert AST.test_file?("test/my_test.exs")
      assert AST.test_file?("test/support/helpers.ex")
    end

    test "returns false for lib files" do
      refute AST.test_file?("lib/my_app/worker.ex")
    end
  end

  describe "contains?/2" do
    test "finds matching nodes in AST" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule Foo do
          def bar, do: Logger.info("hello")
        end
        """)

      assert AST.contains?(ast, fn
               {{:., _, [{:__aliases__, _, [:Logger]}, :info]}, _, _} -> true
               _ -> false
             end)
    end

    test "returns false when no match" do
      {:ok, ast} = Code.string_to_quoted("defmodule Foo do\n  def bar, do: :ok\nend")

      refute AST.contains?(ast, fn
               {{:., _, [{:__aliases__, _, [:Logger]}, _]}, _, _} -> true
               _ -> false
             end)
    end
  end

  describe "find_all/2" do
    test "collects all matching nodes" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule Foo do
          def a, do: Logger.info("one")
          def b, do: Logger.warning("two")
        end
        """)

      matches =
        AST.find_all(ast, fn
          {{:., _, [{:__aliases__, _, [:Logger]}, _]}, _, _} -> true
          _ -> false
        end)

      assert length(matches) == 2
    end
  end

  describe "extract_callbacks/1" do
    test "groups callbacks by name" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule MyServer do
          use GenServer

          def init(args), do: {:ok, args}
          def handle_call(:ping, _from, state), do: {:reply, :pong, state}
          def handle_cast(:reset, state), do: {:noreply, %{}}
          def handle_info(:tick, state), do: {:noreply, state}
        end
        """)

      callbacks = AST.extract_callbacks(ast)
      assert length(callbacks[:init]) == 1
      assert length(callbacks[:handle_call]) == 1
      assert length(callbacks[:handle_cast]) == 1
      assert length(callbacks[:handle_info]) == 1
    end
  end
end
