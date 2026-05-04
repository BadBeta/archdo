defmodule Archdo.Rules.Helpers.LoopDetectionTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Helpers.LoopDetection

  defp parse(code) do
    {:ok, ast} = Code.string_to_quoted(code, columns: true, token_metadata: true)
    ast
  end

  describe "data accessors" do
    test "enum_fns/0 includes the canonical higher-order Enum names" do
      fns = LoopDetection.enum_fns()
      assert :map in fns
      assert :reduce in fns
      assert :flat_map in fns
      assert :filter in fns
    end

    test "stream_fns/0 includes Stream higher-order names" do
      fns = LoopDetection.stream_fns()
      assert :map in fns
      assert :transform in fns
    end

    test "lists_fns/0 includes Erlang :lists names" do
      fns = LoopDetection.lists_fns()
      assert :map in fns
      assert :foldl in fns
    end

    test "genserver_callbacks/0 returns the four hot-path callback atoms" do
      assert LoopDetection.genserver_callbacks() == [
               :handle_call,
               :handle_cast,
               :handle_info,
               :handle_continue
             ]
    end
  end

  describe "find_in_loops/2" do
    # Predicate matching `IO.inspect/_` calls — used by collection_perf
    # rules. Cheap to assert against in tests.
    defp inspect_predicate do
      fn
        {{:., _, [{:__aliases__, _, [:IO]}, :inspect]}, _, _} -> true
        _ -> false
      end
    end

    test "finds matches inside an Enum.map callback" do
      ast = parse(~S"""
      Enum.map(items, fn x -> IO.inspect(x) end)
      """)

      hits = LoopDetection.find_in_loops(ast, inspect_predicate())
      assert hits != []
    end

    test "finds matches inside a Stream.map callback" do
      ast = parse(~S"""
      Stream.map(items, fn x -> IO.inspect(x) end)
      """)

      assert LoopDetection.find_in_loops(ast, inspect_predicate()) != []
    end

    test "returns [] when the loop body has no matches" do
      ast = parse(~S"""
      Enum.map(items, fn x -> x + 1 end)
      """)

      assert LoopDetection.find_in_loops(ast, inspect_predicate()) == []
    end

    test "ignores matches outside any loop construct" do
      ast = parse(~S"""
      defmodule M do
        def f(x), do: IO.inspect(x)
      end
      """)

      # IO.inspect appears, but not inside a loop callback — should miss.
      assert LoopDetection.find_in_loops(ast, inspect_predicate()) == []
    end
  end
end
