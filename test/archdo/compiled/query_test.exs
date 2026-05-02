defmodule Archdo.Compiled.QueryTest do
  use ExUnit.Case, async: true

  alias Archdo.Compiled.{Graph, Query}

  # In-memory fixture graphs — no beam files, no I/O. The Query module
  # is the read API of the Compiled context; its tests stand alone.

  defp call(caller_mfa, callee_mfa, line \\ 1) do
    %{caller: caller_mfa, callee: callee_mfa, line: line}
  end

  defp build_fixture_graph(calls, modules \\ %{}) do
    by_caller = Enum.group_by(calls, & &1.caller)
    by_callee = Enum.group_by(calls, & &1.callee)
    by_module = Enum.group_by(calls, fn c -> elem(c.caller, 0) end)

    %Graph{
      modules: modules,
      calls: calls,
      calls_by_caller: by_caller,
      calls_by_callee: by_callee,
      calls_by_module: by_module
    }
  end

  describe "Query — read API delegated to Graph" do
    test "callers_of/2 returns expected callers" do
      callee = {ModB, :go, 1}
      calls = [call({ModA, :run, 0}, callee), call({ModC, :tick, 0}, callee)]
      graph = build_fixture_graph(calls)

      callers = Query.callers_of(graph, callee)
      assert length(callers) == 2
      callers_mfas = Enum.map(callers, & &1.caller)
      assert {ModA, :run, 0} in callers_mfas
      assert {ModC, :tick, 0} in callers_mfas
    end

    test "callees_of/2 returns expected callees" do
      caller = {ModA, :run, 0}
      calls = [call(caller, {ModB, :go, 1}), call(caller, {ModC, :tick, 0})]
      graph = build_fixture_graph(calls)

      callees = Query.callees_of(graph, caller)
      assert length(callees) == 2
    end

    test "module_dependencies/2 lists target modules excluding self-loops" do
      calls = [
        call({ModA, :run, 0}, {ModB, :go, 1}),
        call({ModA, :run, 0}, {ModC, :tick, 0}),
        call({ModA, :helper, 0}, {ModA, :run, 0})
      ]

      graph = build_fixture_graph(calls)

      deps = Query.module_dependencies(graph, ModA)
      assert ModB in deps
      assert ModC in deps
      refute ModA in deps
    end

    test "module_dependents/2 lists modules calling into the target" do
      calls = [
        call({ModA, :run, 0}, {ModX, :go, 1}),
        call({ModB, :tick, 0}, {ModX, :go, 1}),
        call({ModX, :helper, 0}, {ModX, :go, 1})
      ]

      graph = build_fixture_graph(calls)

      deps = Query.module_dependents(graph, ModX)
      assert ModA in deps
      assert ModB in deps
      refute ModX in deps
    end

    test "callbacks_for/2 returns the callback fns of a behaviour module" do
      modules = %{
        MyBehaviour => %{
          exports: [],
          behaviours: [],
          struct_fields: [],
          callback_fns: [{:handle, 2}, {:render, 1}]
        }
      }

      graph = build_fixture_graph([], modules)

      assert Query.callbacks_for(graph, MyBehaviour) == [{:handle, 2}, {:render, 1}]
    end

    test "callbacks_for/2 returns [] for unknown module" do
      graph = build_fixture_graph([])
      assert Query.callbacks_for(graph, NoSuchMod) == []
    end

    test "external_usage/2 counts external callers per export" do
      modules = %{
        ModA => %{
          exports: [{:run, 0}, {:helper, 0}],
          behaviours: [],
          struct_fields: [],
          callback_fns: []
        }
      }

      calls = [
        call({ModB, :go, 0}, {ModA, :run, 0}),
        call({ModC, :tick, 0}, {ModA, :run, 0}),
        # self-call must not count as external
        call({ModA, :helper, 0}, {ModA, :run, 0})
      ]

      graph = build_fixture_graph(calls, modules)

      usage = Query.external_usage(graph, ModA)
      assert usage[{:run, 0}] == 2
      assert usage[{:helper, 0}] == 0
    end

    test "transitive_dependents/2 walks dependents by depth" do
      calls = [
        call({ModB, :run, 0}, {ModA, :go, 1}),
        call({ModC, :tick, 0}, {ModB, :run, 0}),
        call({ModD, :work, 0}, {ModC, :tick, 0})
      ]

      graph = build_fixture_graph(calls)

      result = Query.transitive_dependents(graph, ModA)
      assert result[1] == [ModB]
      assert result[2] == [ModC]
      assert result[3] == [ModD]
    end

    test "queries against an empty graph return [] / empty consistently" do
      graph = build_fixture_graph([])

      assert Query.callers_of(graph, {Foo, :bar, 0}) == []
      assert Query.callees_of(graph, {Foo, :bar, 0}) == []
      assert Query.module_dependencies(graph, Foo) == []
      assert Query.module_dependents(graph, Foo) == []
      assert Query.callbacks_for(graph, Foo) == []
      assert Query.external_usage(graph, Foo) == %{}
      assert Query.transitive_dependents(graph, Foo) == %{}
    end
  end
end
