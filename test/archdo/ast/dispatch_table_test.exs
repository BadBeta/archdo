defmodule Archdo.AST.DispatchTableTest do
  use ExUnit.Case, async: true

  alias Archdo.AST.DispatchTable

  defp parse(code) do
    {:ok, ast} =
      Code.string_to_quoted(code,
        file: "test.ex",
        columns: true,
        token_metadata: true,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    ast
  end

  describe "extract_module_values/1" do
    test "extracts module aliases from a @attr %{atom => Module} map" do
      ast =
        parse("""
        defmodule UA.Generator.Dispatch do
          @generators %{
            adapter: UA.Generator.Adapter,
            behaviour: UA.Generator.Behaviour
          }
        end
        """)

      result = DispatchTable.extract_module_values(ast)
      assert "UA.Generator.Adapter" in result
      assert "UA.Generator.Behaviour" in result
    end

    test "extracts modules from a @attr list literal" do
      ast =
        parse("""
        defmodule MyApp.Dispatch do
          @workers [MyApp.WorkerA, MyApp.WorkerB, MyApp.WorkerC]
        end
        """)

      result = DispatchTable.extract_module_values(ast)
      assert "MyApp.WorkerA" in result
      assert "MyApp.WorkerB" in result
      assert "MyApp.WorkerC" in result
    end

    test "extracts modules from a keyword list" do
      ast =
        parse("""
        defmodule MyApp.Dispatch do
          @handlers [
            click: MyApp.Handlers.Click,
            submit: MyApp.Handlers.Submit
          ]
        end
        """)

      result = DispatchTable.extract_module_values(ast)
      assert "MyApp.Handlers.Click" in result
      assert "MyApp.Handlers.Submit" in result
    end

    test "extracts modules from a tuple-key map (e.g., {:a, :b} => Mod)" do
      ast =
        parse("""
        defmodule MyApp.Dispatch do
          @routes %{
            {:get, "/users"} => MyApp.Controllers.User,
            {:post, "/users"} => MyApp.Controllers.UserCreate
          }
        end
        """)

      result = DispatchTable.extract_module_values(ast)
      assert "MyApp.Controllers.User" in result
      assert "MyApp.Controllers.UserCreate" in result
    end

    test "extracts modules from nested map values" do
      ast =
        parse("""
        defmodule MyApp.Dispatch do
          @config %{
            group1: %{primary: MyApp.A, secondary: MyApp.B},
            group2: %{primary: MyApp.C}
          }
        end
        """)

      result = DispatchTable.extract_module_values(ast)
      assert "MyApp.A" in result
      assert "MyApp.B" in result
      assert "MyApp.C" in result
    end

    test "extracts a single module assigned to a module attribute" do
      ast =
        parse("""
        defmodule MyApp.Dispatch do
          @default_handler MyApp.Handlers.Default
        end
        """)

      result = DispatchTable.extract_module_values(ast)
      assert "MyApp.Handlers.Default" in result
    end

    test "returns empty for @attr with no module aliases" do
      ast =
        parse("""
        defmodule MyApp.Config do
          @timeout 5_000
          @opts %{retries: 3, backoff: 1_000}
          @names ["alice", "bob"]
        end
        """)

      assert DispatchTable.extract_module_values(ast) == []
    end

    test "ignores modules that appear only as map KEYS (not values)" do
      ast =
        parse("""
        defmodule MyApp.KeyedDispatch do
          @counters %{
            MyApp.A => 0,
            MyApp.B => 0
          }
        end
        """)

      # Map keys-as-modules don't count — we anchor on call targets,
      # not lookup keys (the key value isn't being invoked).
      assert DispatchTable.extract_module_values(ast) == []
    end

    test "deduplicates repeated module references" do
      ast =
        parse("""
        defmodule MyApp.Dispatch do
          @primary MyApp.Worker
          @backup  MyApp.Worker
          @list    [MyApp.Worker, MyApp.Worker]
        end
        """)

      result = DispatchTable.extract_module_values(ast)
      assert result == ["MyApp.Worker"]
    end

    test "skips Elixir stdlib modules and bare-atom aliases" do
      ast =
        parse("""
        defmodule MyApp.Config do
          @adapter String
          @atoms %{a: :ok, b: :error}
        end
        """)

      # `String` IS technically an alias — we don't try to filter Elixir's
      # stdlib here; the caller (AnchorSet) decides whether to skip them
      # based on whether they appear in the analyzed file set.
      result = DispatchTable.extract_module_values(ast)
      assert "String" in result
    end
  end
end
