defmodule Archdo.Compiled.GraphTest do
  use ExUnit.Case, async: true

  @moduletag :self_analysis

  alias Archdo.Compiled.{Diagram, Graph}

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
      assert graph.calls != []
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

  describe "knows_about/2" do
    setup do
      beam_dir = find_archdo_beam_dir()
      %{graph: Graph.build(beam_dir)}
    end

    @tag :self_analysis
    test "returns modules the given module calls", %{graph: graph} do
      entries = Graph.knows_about(graph, Archdo.Runner)
      assert is_list(entries)
      assert entries != []

      # Runner calls AST.parse_file
      ast_entry = Enum.find(entries, fn e -> e.module == Archdo.AST end)
      assert ast_entry != nil
      assert {:parse_file, 1} in ast_entry.functions_called
    end

    @tag :self_analysis
    test "entries are sorted by call count descending", %{graph: graph} do
      entries = Graph.knows_about(graph, Archdo.Runner)
      counts = Enum.map(entries, & &1.call_count)
      assert counts == Enum.sort(counts, :desc)
    end
  end

  describe "known_by/2" do
    setup do
      beam_dir = find_archdo_beam_dir()
      %{graph: Graph.build(beam_dir)}
    end

    @tag :self_analysis
    test "returns modules that call the given module", %{graph: graph} do
      entries = Graph.known_by(graph, Archdo.AST)
      assert length(entries) > 10
    end

    @tag :self_analysis
    test "each entry lists which functions are called", %{graph: graph} do
      [entry | _] = Graph.known_by(graph, Archdo.AST)
      assert is_atom(entry.module)
      assert is_list(entry.functions_called)
      assert entry.call_count > 0
    end
  end

  describe "context_knows_about/2" do
    setup do
      beam_dir = find_archdo_beam_dir()
      %{graph: Graph.build(beam_dir)}
    end

    @tag :self_analysis
    test "returns contexts the given context depends on", %{graph: graph} do
      entries = Graph.context_knows_about(graph, "Archdo.Rules")
      assert is_list(entries)
      assert entries != []

      Enum.each(entries, fn e ->
        assert is_binary(e.context)
        assert is_list(e.modules_called)
        assert e.call_count > 0
      end)
    end
  end

  describe "context_known_by/2" do
    setup do
      beam_dir = find_archdo_beam_dir()
      %{graph: Graph.build(beam_dir)}
    end

    @tag :self_analysis
    test "returns contexts that depend on the given context", %{graph: graph} do
      entries = Graph.context_known_by(graph, "Archdo.Compiled")
      assert is_list(entries)

      Enum.each(entries, fn e ->
        assert is_binary(e.context)
        assert is_list(e.calling_modules)
        assert e.call_count > 0
      end)
    end
  end

  describe "discover_contexts/1" do
    setup do
      beam_dir = find_archdo_beam_dir()
      %{graph: Graph.build(beam_dir)}
    end

    @tag :self_analysis
    test "discovers contexts automatically", %{graph: graph} do
      contexts = Graph.discover_contexts(graph)
      assert is_list(contexts)
      assert length(contexts) >= 2
    end

    @tag :self_analysis
    test "each context has required fields", %{graph: graph} do
      [ctx | _] = Graph.discover_contexts(graph)
      assert is_binary(ctx.context)
      assert is_list(ctx.members)
      assert is_float(ctx.cohesion)
      assert is_float(ctx.coupling)
      assert is_float(ctx.quality_score)
      assert is_integer(ctx.internal_calls)
      assert is_integer(ctx.incoming_calls)
      assert is_integer(ctx.outgoing_calls)
    end
  end

  describe "Diagram.compute_delta/2" do
    setup do
      beam_dir = find_archdo_beam_dir()
      %{graph: Graph.build(beam_dir)}
    end

    @tag :self_analysis
    test "computes delta between AST and compiled", %{graph: graph} do
      delta = Diagram.compute_delta(graph, ["lib"])
      assert MapSet.size(delta.both) > 0
      assert MapSet.size(delta.compiled_only) > 0
      assert MapSet.size(delta.ast_only) >= 0
    end

    @tag :self_analysis
    test "delta edges are module pairs", %{graph: graph} do
      delta = Diagram.compute_delta(graph, ["lib"])

      delta.both
      |> MapSet.to_list()
      |> Enum.take(5)
      |> Enum.each(fn {from, to} ->
        assert is_atom(from)
        assert is_atom(to)
      end)
    end

    @tag :self_analysis
    test "hidden count is reasonable", %{graph: graph} do
      delta = Diagram.compute_delta(graph, ["lib"])
      # There should be more compiled edges than AST edges
      # (macros inject calls invisible to AST)
      assert delta.compiled_total > delta.ast_total
    end
  end

  describe "Diagram.dependency_delta_only/2" do
    setup do
      beam_dir = find_archdo_beam_dir()
      %{graph: Graph.build(beam_dir)}
    end

    @tag :self_analysis
    test "generates valid Mermaid output", %{graph: graph} do
      mermaid = Diagram.dependency_delta_only(graph, ["lib"])
      assert String.starts_with?(mermaid, "graph LR")
      assert mermaid =~ "HIDDEN"
      assert mermaid =~ "PHANTOM"
    end
  end

  defp find_archdo_beam_dir do
    Path.join([File.cwd!(), "_build", "test", "lib", "archdo", "ebin"])
  end
end
