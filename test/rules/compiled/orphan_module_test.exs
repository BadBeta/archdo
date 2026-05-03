defmodule Archdo.Rules.Compiled.OrphanModuleTest do
  use ExUnit.Case, async: true

  @moduletag :self_analysis

  alias Archdo.Compiled.Graph
  alias Archdo.Rules.Compiled.OrphanModule

  setup_all do
    beam_dir = Path.join([File.cwd!(), "_build", "test", "lib", "archdo", "ebin"])
    graph = Graph.build(beam_dir)
    %{graph: graph}
  end

  describe "rule metadata" do
    test "has correct id" do
      assert OrphanModule.id() == "1.25"
    end

    test "has a description" do
      assert is_binary(OrphanModule.description())
    end

    test "AST-mode analyze/3 is not implemented (project-only rule)" do
      refute function_exported?(OrphanModule, :analyze, 3)
    end
  end

  describe "analyze_compiled/1" do
    test "returns a list of diagnostics", %{graph: graph} do
      diagnostics = OrphanModule.analyze_compiled(graph)
      assert is_list(diagnostics)
      assert Enum.all?(diagnostics, &(&1.rule_id == "1.25"))
    end

    test "all diagnostics have :info severity", %{graph: graph} do
      diagnostics = OrphanModule.analyze_compiled(graph)

      Enum.each(diagnostics, fn diag ->
        assert diag.severity == :info
        assert diag.title == "Orphan module"
        assert is_binary(diag.message)
        assert is_binary(diag.context.module)
      end)
    end

    test "does not flag well-connected modules like Archdo.AST", %{graph: graph} do
      diagnostics = OrphanModule.analyze_compiled(graph)
      modules = Enum.map(diagnostics, fn d -> d.context.module end)

      refute Enum.member?(modules, "Archdo.AST"),
             "Archdo.AST has many dependents — should not be flagged as orphan"
    end

    test "does not flag Archdo.Diagnostic", %{graph: graph} do
      diagnostics = OrphanModule.analyze_compiled(graph)
      modules = Enum.map(diagnostics, fn d -> d.context.module end)

      refute Enum.member?(modules, "Archdo.Diagnostic"),
             "Archdo.Diagnostic is used everywhere — should not be flagged as orphan"
    end
  end

  describe "exclusions" do
    test "does not flag Application modules" do
      graph = %Graph{
        modules: %{
          MyApp.Application => %{
            exports: [{:start, 2}],
            behaviours: [Application],
            struct_fields: [],
            callback_fns: []
          }
        },
        calls: [],
        calls_by_caller: %{},
        calls_by_callee: %{},
        calls_by_module: %{},
        protocol_impls: %{},
        struct_expansions: []
      }

      diagnostics = OrphanModule.analyze_compiled(graph)
      assert diagnostics == []
    end

    test "does not flag behaviour definitions" do
      graph = %Graph{
        modules: %{
          MyApp.Storage => %{
            exports: [{:behaviour_info, 1}],
            behaviours: [],
            struct_fields: [],
            callback_fns: [{:fetch, 1}, {:store, 2}]
          }
        },
        calls: [],
        calls_by_caller: %{},
        calls_by_callee: %{},
        calls_by_module: %{},
        protocol_impls: %{},
        struct_expansions: []
      }

      diagnostics = OrphanModule.analyze_compiled(graph)
      assert diagnostics == []
    end

    test "flags a truly orphan module" do
      graph = %Graph{
        modules: %{
          MyApp.Orphan => %{
            exports: [{:do_stuff, 0}],
            behaviours: [],
            struct_fields: [],
            callback_fns: []
          },
          MyApp.Connected => %{
            exports: [{:work, 0}],
            behaviours: [],
            struct_fields: [],
            callback_fns: []
          }
        },
        calls: [
          %{caller: {MyApp.Connected, :work, 0}, callee: {SomeOther, :thing, 0}, line: 5}
        ],
        calls_by_caller: %{
          {MyApp.Connected, :work, 0} => [
            %{caller: {MyApp.Connected, :work, 0}, callee: {SomeOther, :thing, 0}, line: 5}
          ]
        },
        calls_by_callee: %{
          {SomeOther, :thing, 0} => [
            %{caller: {MyApp.Connected, :work, 0}, callee: {SomeOther, :thing, 0}, line: 5}
          ]
        },
        calls_by_module: %{
          MyApp.Connected => [
            %{caller: {MyApp.Connected, :work, 0}, callee: {SomeOther, :thing, 0}, line: 5}
          ]
        },
        protocol_impls: %{},
        struct_expansions: []
      }

      diagnostics = OrphanModule.analyze_compiled(graph)
      assert length(diagnostics) == 1
      [diag] = diagnostics
      assert diag.context.module == "MyApp.Orphan"
    end
  end
end
