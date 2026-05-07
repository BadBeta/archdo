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

  describe "Graph.production_beam?/1 — test-source filter" do
    # A BEAM in a library's `_build/<env>/lib/<app>/ebin/` directory may
    # have been compiled from a `test/` source (test helpers, support
    # modules). The user's `--paths lib/` argument means "scan production
    # code"; the AST side already filters via `AST.test_file?/1`. The
    # compiled side reads every `Elixir.*.beam` indiscriminately, so the
    # call graph and module set leak test helpers — they show up as
    # 1.26 orphans because no production module reaches them.
    #
    # Fix: examine each BEAM's `:compile_info[:source]` and skip beams
    # whose source path matches `AST.test_file?/1`.

    test "returns true for a BEAM compiled from a lib/ source" do
      beam_path =
        Path.join([
          File.cwd!(),
          "_build",
          "test",
          "lib",
          "archdo",
          "ebin",
          "Elixir.Archdo.AST.beam"
        ])

      assert File.exists?(beam_path),
             "expected Archdo's own AST module BEAM at #{beam_path}"

      assert Graph.production_beam?(to_charlist(beam_path))
    end

    test "returns false for a BEAM compiled from a test/ source" do
      # Use Archdo's own test_helpers if compiled, otherwise mock.
      # Simplest: fabricate a synthetic BEAM-like check by passing a
      # path-like string that we know contains `/test/`. The implementation
      # uses `:beam_lib.chunks/2`; for unit-test isolation, expose a
      # pure helper that takes the source charlist directly.
      assert Graph.production_source?(~c"/some/project/lib/foo.ex")
      refute Graph.production_source?(~c"/some/project/test/helpers/foo.ex")
      refute Graph.production_source?(~c"/some/project/test/support/foo.ex")
      refute Graph.production_source?(~c"test/helpers/foo.ex")
    end
  end

  describe "Graph.find_remote_calls/1 — args-nested recursion" do
    # Critical bug surfaced during M-fp-F2 PS-investigation: the matcher
    # had a non-recursive happy-path. When it matched an outer call, it
    # returned that call WITHOUT descending into args — so any nested
    # remote call inside an arg was silently dropped. Symptom: PS calls
    # Subscriber.new/1 inside `subscribers ++ [Subscriber.new(pid)]`. The
    # outer call is :erlang.++/2; without args-recursion only :erlang.++
    # is recorded and Subscriber.new is invisible to the call graph.
    # Effect: 1.26 flags Subscriber as orphan, every Enum/Stream-wrapped
    # callsite across the corpus loses the inner callee.

    test "captures the outer remote call" do
      # Hand-built `Foo.bar()` — a single direct call.
      form =
        {:call, 1, {:remote, 1, {:atom, 1, Foo}, {:atom, 1, :bar}}, []}

      assert Graph.find_remote_calls(form) == [{Foo, :bar, 0, 1}]
    end

    test "captures a call nested inside another call's args (the missing case)" do
      # `Enum.map(coll, &Subscriber.process/1)` — the inner Subscriber.process
      # call is wrapped as a fun-capture, but the same shape applies for
      # `Enum.map(coll, fn x -> Subscriber.process(x) end)` where the body
      # is a `{:call, ...}` inside the args list.
      #
      # Concretely: `:erlang.++(subscribers, [Subscriber.new(pid)])` from
      # the audit. Inner :call must be picked up.
      inner_call =
        {:call, 26, {:remote, 26, {:atom, 26, Sub}, {:atom, 26, :new}}, [{:var, 26, :_pid}]}

      outer_call =
        {:call, 26, {:remote, 26, {:atom, 26, :erlang}, {:atom, 26, :++}},
         [{:var, 26, :_subs}, {:cons, 26, inner_call, {nil, 26}}]}

      results = Graph.find_remote_calls(outer_call)

      mfas = Enum.map(results, fn {m, f, a, _line} -> {m, f, a} end)
      assert {:erlang, :++, 2} in mfas
      assert {Sub, :new, 1} in mfas
    end

    test "captures multiple nested calls in the same args list" do
      # `Enum.find(xs, &Helper.match?/1)` AND `Enum.map(xs, &Helper.transform/1)`
      # — both inner calls must be recorded.
      call_a =
        {:call, 10, {:remote, 10, {:atom, 10, Inner}, {:atom, 10, :a}}, []}

      call_b =
        {:call, 11, {:remote, 11, {:atom, 11, Inner}, {:atom, 11, :b}}, []}

      outer =
        {:call, 9, {:remote, 9, {:atom, 9, Outer}, {:atom, 9, :combine}}, [call_a, call_b]}

      results = Graph.find_remote_calls(outer)
      mfas = Enum.map(results, fn {m, f, a, _l} -> {m, f, a} end)

      assert {Outer, :combine, 2} in mfas
      assert {Inner, :a, 0} in mfas
      assert {Inner, :b, 0} in mfas
    end

    test "captures deeply-nested call chain" do
      innermost =
        {:call, 3, {:remote, 3, {:atom, 3, Deep}, {:atom, 3, :end}}, []}

      mid =
        {:call, 2, {:remote, 2, {:atom, 2, Mid}, {:atom, 2, :wrap}}, [innermost]}

      top =
        {:call, 1, {:remote, 1, {:atom, 1, Top}, {:atom, 1, :go}}, [mid]}

      mfas =
        top
        |> Graph.find_remote_calls()
        |> Enum.map(fn {m, f, a, _l} -> {m, f, a} end)

      assert {Top, :go, 1} in mfas
      assert {Mid, :wrap, 1} in mfas
      assert {Deep, :end, 0} in mfas
    end

    test "non-call forms recurse without spurious results" do
      # `{:tuple, _, [...]}` containing a call.
      inner =
        {:call, 5, {:remote, 5, {:atom, 5, M}, {:atom, 5, :f}}, []}

      tuple_form = {:tuple, 5, [inner]}
      assert Graph.find_remote_calls(tuple_form) == [{M, :f, 0, 5}]
    end

    test "captures function references (`&Mod.fn/arity`)" do
      # Captures compile to the abstract-code form
      # `{:fun, line, {:function, {:atom, _, mod}, {:atom, _, fn}, {:integer, _, arity}}}`.
      # Without matching this, calls passed as `&Mod.fn/n` (very common
      # in `Enum.find/filter/map/sort_by` patterns) are invisible to the
      # call graph. Symptom: `Subscriber.available?/1` (called via
      # `Enum.find(subs, &Subscriber.available?/1)`) flagged as dead.
      capture =
        {:fun, 7, {:function, {:atom, 7, Subscriber}, {:atom, 7, :available?}, {:integer, 7, 1}}}

      assert Graph.find_remote_calls(capture) == [{Subscriber, :available?, 1, 7}]
    end

    test "captures function references nested inside another call's args" do
      # `Enum.find(subs, &Subscriber.available?/1)`
      capture =
        {:fun, 7, {:function, {:atom, 7, Sub}, {:atom, 7, :available?}, {:integer, 7, 1}}}

      outer =
        {:call, 7, {:remote, 7, {:atom, 7, Enum}, {:atom, 7, :find}},
         [{:var, 7, :_subs}, capture]}

      mfas =
        outer
        |> Graph.find_remote_calls()
        |> Enum.map(fn {m, f, a, _l} -> {m, f, a} end)

      assert {Enum, :find, 2} in mfas
      assert {Sub, :available?, 1} in mfas
    end
  end
end
