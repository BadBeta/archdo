defmodule Archdo.FunctionGraphTest do
  use ExUnit.Case, async: true

  alias Archdo.{AST, FunctionGraph}

  defp parse(code, file) do
    {:ok, ast} = Code.string_to_quoted(code, file: file, columns: true)
    {file, ast}
  end

  defp call_for(graph, target_module, target_fn) do
    Enum.find(graph.calls, fn c ->
      c.target_module == target_module and c.target_fn == target_fn
    end)
  end

  describe "defdelegate registration" do
    test "defdelegate name(args), to: ... registers as a public function" do
      file =
        parse(
          ~S"""
          defmodule MyApp.Facade do
            defdelegate phase1_rules(), to: MyApp.Rules
            defdelegate modules(graph), to: MyApp.Graph
            defdelegate normalize(mod), to: MyApp.AST, as: :module_name
          end
          """,
          "lib/facade.ex"
        )

      graph = FunctionGraph.build([file])

      assert %{visibility: :public, name: :phase1_rules, arity: 0} =
               Map.get(graph.definitions, {"MyApp.Facade", :phase1_rules, 0})

      assert %{visibility: :public, name: :modules, arity: 1} =
               Map.get(graph.definitions, {"MyApp.Facade", :modules, 1})

      assert %{visibility: :public, name: :normalize, arity: 1} =
               Map.get(graph.definitions, {"MyApp.Facade", :normalize, 1})
    end
  end

  describe "pipe-aware arity (regression for rule 1.7 false positives)" do
    test "remote call on the rhs of |> counts the piped value as arg 1" do
      file =
        parse(
          ~S"""
          defmodule MyApp.Caller do
            def run(diags, opts) do
              diags
              |> Other.filter(opts)
              |> Enum.count()
            end
          end
          """,
          "lib/caller.ex"
        )

      graph = FunctionGraph.build([file])

      filter_call = call_for(graph, "Other", :filter)
      assert filter_call, "Expected a call to Other.filter to be recorded"

      assert filter_call.target_arity == 2,
             "x |> Other.filter(opts) should resolve to filter/2, got /#{filter_call.target_arity}"

      count_call = call_for(graph, "Enum", :count)
      assert count_call, "Expected a call to Enum.count to be recorded"

      assert count_call.target_arity == 1,
             "x |> Enum.count() should resolve to count/1, got /#{count_call.target_arity}"
    end

    test "remote call NOT in pipe position keeps its declared arity" do
      file =
        parse(
          ~S"""
          defmodule MyApp.Caller do
            def run(opts) do
              Other.filter(opts)
            end
          end
          """,
          "lib/caller.ex"
        )

      graph = FunctionGraph.build([file])

      assert call_for(graph, "Other", :filter).target_arity == 1
    end
  end
end
