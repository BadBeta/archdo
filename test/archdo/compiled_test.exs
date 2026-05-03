defmodule Archdo.CompiledTest do
  use ExUnit.Case, async: true

  alias Archdo.Compiled
  alias Archdo.Compiled.Graph

  # In-memory fixture — Compiled accessor surface should be testable
  # without spinning up the full beam-analysis pipeline.

  describe "Compiled — boundary accessors (M-Plan19 Phase 3)" do
    setup do
      call = %{caller: {ModA, :run, 0}, callee: {ModB, :go, 1}, line: 42}

      graph = %Graph{
        modules: %{
          ModA => %{exports: [{:run, 0}], behaviours: [], struct_fields: [], callback_fns: []}
        },
        calls: [call],
        calls_by_caller: %{{ModA, :run, 0} => [call]},
        calls_by_callee: %{{ModB, :go, 1} => [call]},
        calls_by_module: %{ModA => [call]},
        beam_dir: "/tmp/_build/dev/lib/myapp/ebin"
      }

      %{graph: graph, call: call}
    end

    test "calls/1 returns the calls list", %{graph: graph, call: call} do
      assert Compiled.calls(graph) == [call]
    end

    test "modules/1 returns the modules map", %{graph: graph} do
      modules = Compiled.modules(graph)
      assert is_map(modules)
      assert Map.has_key?(modules, ModA)
    end

    test "calls_by_module/1 returns the per-caller-module index", %{graph: graph, call: call} do
      assert Compiled.calls_by_module(graph) == %{ModA => [call]}
    end

    test "calls_by_callee/1 returns the per-callee-mfa index", %{graph: graph, call: call} do
      assert Compiled.calls_by_callee(graph) == %{{ModB, :go, 1} => [call]}
    end

    test "beam_dir/1 returns the build directory", %{graph: graph} do
      assert Compiled.beam_dir(graph) == "/tmp/_build/dev/lib/myapp/ebin"
    end

    test "accessors return [] / %{} / nil for an empty graph" do
      empty = %Graph{}
      assert Compiled.calls(empty) == []
      assert Compiled.modules(empty) == %{}
      assert Compiled.calls_by_module(empty) == %{}
      assert Compiled.calls_by_callee(empty) == %{}
      assert Compiled.beam_dir(empty) == nil
    end
  end
end
