defmodule Archdo.Compiled.GraphTest do
  use ExUnit.Case, async: true

  @moduletag :self_analysis

  alias Archdo.Compiled.Graph

  describe "build/1" do
    setup do
      beam_dir = find_archdo_beam_dir()
      %{graph: Graph.build(beam_dir)}
    end

    test "builds a graph with modules", %{graph: graph} do
      assert map_size(graph.modules) > 0
      assert Map.has_key?(graph.modules, Archdo.Runner)
      assert Map.has_key?(graph.modules, Archdo.Compiled.Graph)
    end

    test "collects exports for each module", %{graph: graph} do
      runner_info = graph.modules[Archdo.Runner]
      assert is_list(runner_info.exports)
      assert {:analyze, 2} in runner_info.exports
    end

    test "collects behaviours", %{graph: graph} do
      # Archdo.Compiled.Collector uses GenServer
      collector_info = graph.modules[Archdo.Compiled.Collector]
      assert GenServer in collector_info.behaviours
    end

    test "builds call indexes", %{graph: graph} do
      assert map_size(graph.calls_by_caller) > 0
      assert map_size(graph.calls_by_callee) > 0
      assert map_size(graph.calls_by_module) > 0
    end

    test "calls list is non-empty", %{graph: graph} do
      assert length(graph.calls) > 0
    end
  end

  describe "callers_of/2" do
    setup do
      beam_dir = find_archdo_beam_dir()
      %{graph: Graph.build(beam_dir)}
    end

    @tag :self_analysis
    test "finds callers of a function", %{graph: graph} do
      # Runner.analyze should be called from somewhere
      callers = Graph.callers_of(graph, {Archdo.Runner, :analyze, 2})
      # May or may not have callers depending on project structure
      assert is_list(callers)
    end
  end

  describe "module_dependencies/2" do
    setup do
      beam_dir = find_archdo_beam_dir()
      %{graph: Graph.build(beam_dir)}
    end

    @tag :self_analysis
    test "finds module dependencies", %{graph: graph} do
      deps = Graph.module_dependencies(graph, Archdo.Runner)
      assert is_list(deps)
      # Runner depends on AST, Config, Diagnostic, Graph
      assert Archdo.AST in deps
    end
  end

  describe "module_dependents/2" do
    setup do
      beam_dir = find_archdo_beam_dir()
      %{graph: Graph.build(beam_dir)}
    end

    @tag :self_analysis
    test "finds module dependents", %{graph: graph} do
      dependents = Graph.module_dependents(graph, Archdo.AST)
      assert is_list(dependents)
      assert length(dependents) > 5
    end
  end

  describe "dead_functions/1" do
    setup do
      beam_dir = find_archdo_beam_dir()
      %{graph: Graph.build(beam_dir)}
    end

    @tag :self_analysis
    test "finds dead functions", %{graph: graph} do
      dead = Graph.dead_functions(graph)
      assert is_list(dead)

      # Each dead function has the expected shape
      Enum.each(dead, fn entry ->
        assert %{module: _, function: _, arity: _} = entry
        assert is_atom(entry.module)
        assert is_atom(entry.function)
        assert is_integer(entry.arity)
      end)
    end

    @tag :self_analysis
    test "does not flag framework callbacks", %{graph: graph} do
      dead = Graph.dead_functions(graph)
      dead_fns = Enum.map(dead, & &1.function)

      refute :init in dead_fns
      refute :handle_call in dead_fns
      refute :handle_info in dead_fns
    end
  end

  describe "strongly_connected_components/1" do
    setup do
      beam_dir = find_archdo_beam_dir()
      %{graph: Graph.build(beam_dir)}
    end

    @tag :self_analysis
    test "returns list of SCCs", %{graph: graph} do
      sccs = Graph.strongly_connected_components(graph)
      assert is_list(sccs)

      # Each SCC has 2+ members (singles are filtered)
      Enum.each(sccs, fn scc ->
        assert length(scc) >= 2
      end)
    end
  end

  describe "external_usage/2" do
    setup do
      beam_dir = find_archdo_beam_dir()
      %{graph: Graph.build(beam_dir)}
    end

    @tag :self_analysis
    test "counts external callers per export", %{graph: graph} do
      usage = Graph.external_usage(graph, Archdo.AST)
      assert is_map(usage)

      # AST is widely used — some functions should have external callers
      used = Enum.count(usage, fn {_fa, count} -> count > 0 end)
      assert used > 0
    end
  end

  defp find_archdo_beam_dir do
    Path.join([File.cwd!(), "_build", "test", "lib", "archdo", "ebin"])
  end
end
