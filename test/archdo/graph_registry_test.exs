defmodule Archdo.GraphRegistryTest do
  use ExUnit.Case, async: true

  alias Archdo.Graph

  defp parse(file, code) do
    {:ok, ast} =
      Code.string_to_quoted(code,
        file: file,
        columns: true,
        token_metadata: true,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    {file, ast}
  end

  describe "M-Aux1 — module-attribute registry edges" do
    test "emits :registry edges when an alias-list attribute is iterated" do
      file_asts = [
        parse("lib/myapp/runner.ex", ~S"""
        defmodule MyApp.Runner do
          @rules [MyApp.RuleA, MyApp.RuleB, MyApp.RuleC]

          def run do
            Enum.each(@rules, fn r -> r.execute() end)
          end
        end
        """)
      ]

      graph = Graph.build(file_asts)
      targets = graph |> Graph.dependencies("MyApp.Runner") |> Enum.map(& &1.target)

      assert "MyApp.RuleA" in targets
      assert "MyApp.RuleB" in targets
      assert "MyApp.RuleC" in targets
    end

    test "no edges when attribute is defined but never iterated" do
      file_asts = [
        parse("lib/myapp/holder.ex", ~S"""
        defmodule MyApp.Holder do
          @reference [MyApp.NotUsed]

          def go(x), do: x
        end
        """)
      ]

      graph = Graph.build(file_asts)
      targets = graph |> Graph.dependencies("MyApp.Holder") |> Enum.map(& &1.target)

      refute "MyApp.NotUsed" in targets
    end

    test "emits edges when attribute is iterated via for-comprehension" do
      file_asts = [
        parse("lib/myapp/forrunner.ex", ~S"""
        defmodule MyApp.ForRunner do
          @plugins [MyApp.PluginA, MyApp.PluginB]

          def run do
            for plugin <- @plugins, do: plugin.go()
          end
        end
        """)
      ]

      graph = Graph.build(file_asts)
      targets = graph |> Graph.dependencies("MyApp.ForRunner") |> Enum.map(& &1.target)

      assert "MyApp.PluginA" in targets
      assert "MyApp.PluginB" in targets
    end

    test "emits edges when attribute is iterated via Stream" do
      file_asts = [
        parse("lib/myapp/streamer.ex", ~S"""
        defmodule MyApp.Streamer do
          @workers [MyApp.W1, MyApp.W2]

          def run do
            @workers |> Stream.map(& &1.tick()) |> Stream.run()
          end
        end
        """)
      ]

      graph = Graph.build(file_asts)
      targets = graph |> Graph.dependencies("MyApp.Streamer") |> Enum.map(& &1.target)

      assert "MyApp.W1" in targets
      assert "MyApp.W2" in targets
    end

    test "does NOT emit edges when attribute holds non-alias values" do
      file_asts = [
        parse("lib/myapp/nums.ex", ~S"""
        defmodule MyApp.Nums do
          @stable_ints [0, 1, -1, 100, 200]

          def stable?(n), do: Enum.member?(@stable_ints, n)
        end
        """)
      ]

      graph = Graph.build(file_asts)

      registry_edges =
        graph |> Graph.dependencies("MyApp.Nums") |> Enum.filter(&(&1.type == :registry))

      assert registry_edges == []
    end

    test "edge type is :registry distinguishing from :alias / :call" do
      file_asts = [
        parse("lib/myapp/regs.ex", ~S"""
        defmodule MyApp.Regs do
          @rules [MyApp.RuleX]
          def run, do: Enum.each(@rules, & &1.go())
        end
        """)
      ]

      graph = Graph.build(file_asts)

      assert Enum.any?(graph.edges, fn e ->
               e.source == "MyApp.Regs" and e.target == "MyApp.RuleX" and e.type == :registry
             end)
    end
  end

  describe "M-Plan8 — apply/3 dynamic dispatch edges" do
    test "emits :dynamic_dispatch edge for apply(LiteralModule, :fn, args)" do
      file_asts = [
        parse("lib/myapp/dispatcher.ex", ~S"""
        defmodule MyApp.Dispatcher do
          def call(arg) do
            apply(MyApp.Target, :run, [arg])
          end
        end
        """)
      ]

      graph = Graph.build(file_asts)
      targets = graph |> Graph.dependencies("MyApp.Dispatcher") |> Enum.map(& &1.target)

      assert "MyApp.Target" in targets,
             "expected MyApp.Target in #{inspect(targets)}"
    end

    test "edge type is :dynamic_dispatch (distinguishes from :call)" do
      file_asts = [
        parse("lib/myapp/d.ex", ~S"""
        defmodule MyApp.D do
          def run, do: apply(MyApp.X, :go, [])
        end
        """)
      ]

      graph = Graph.build(file_asts)

      assert Enum.any?(graph.edges, fn e ->
               e.source == "MyApp.D" and e.target == "MyApp.X" and
                 e.type == :dynamic_dispatch
             end),
             "expected dynamic_dispatch edge MyApp.D → MyApp.X"
    end

    test "no edge for apply(var, :fn, args) — variable target" do
      # Cannot statically resolve a variable target; rule should
      # silently not emit (NOT crash and NOT emit a stray edge).
      file_asts = [
        parse("lib/myapp/var.ex", ~S"""
        defmodule MyApp.Var do
          def call(mod, arg), do: apply(mod, :run, [arg])
        end
        """)
      ]

      graph = Graph.build(file_asts)
      targets = graph |> Graph.dependencies("MyApp.Var") |> Enum.map(& &1.target)

      assert targets == [], "expected no targets, got #{inspect(targets)}"
    end
  end

  describe "M-CG44 — alias-table resolution" do
    test "alias Foo.{Bar, Baz} multi-alias form emits one edge per branch" do
      file_asts = [
        parse("lib/myapp/caller.ex", ~S"""
        defmodule MyApp.Caller do
          alias MyApp.{Runner, Rules}

          def run, do: Runner.start()
          def list, do: Rules.all()
        end
        """)
      ]

      graph = Graph.build(file_asts)
      edges = Graph.dependencies(graph, "MyApp.Caller")

      alias_targets =
        edges
        |> Enum.filter(&(&1.type == :alias))
        |> Enum.map(& &1.target)
        |> Enum.sort()

      assert alias_targets == ["MyApp.Rules", "MyApp.Runner"]
    end

    test "short-form call resolves through alias table" do
      # Without alias-table threading, `Runner.start()` after
      # `alias MyApp.Runner` would create a dangling edge to bare
      # "Runner" — no module by that name. The closure walk needs
      # the fully-qualified target to traverse from Caller to Runner.
      file_asts = [
        parse("lib/myapp/caller.ex", ~S"""
        defmodule MyApp.Caller do
          alias MyApp.Runner

          def run, do: Runner.start()
        end
        """)
      ]

      graph = Graph.build(file_asts)

      call_targets =
        graph
        |> Graph.dependencies("MyApp.Caller")
        |> Enum.filter(&(&1.type == :call))
        |> Enum.map(& &1.target)

      assert "MyApp.Runner" in call_targets
      refute "Runner" in call_targets
    end

    test "short-form call resolves through multi-alias table" do
      file_asts = [
        parse("lib/myapp/caller.ex", ~S"""
        defmodule MyApp.Caller do
          alias MyApp.{Runner, Rules}

          def run do
            Runner.start()
            Rules.all()
          end
        end
        """)
      ]

      graph = Graph.build(file_asts)

      call_targets =
        graph
        |> Graph.dependencies("MyApp.Caller")
        |> Enum.filter(&(&1.type == :call))
        |> Enum.map(& &1.target)
        |> Enum.sort()

      assert "MyApp.Rules" in call_targets
      assert "MyApp.Runner" in call_targets
    end

    test "alias Foo.Bar, as: Quux binds Quux to Foo.Bar" do
      file_asts = [
        parse("lib/myapp/caller.ex", ~S"""
        defmodule MyApp.Caller do
          alias MyApp.LongName.Module, as: Short

          def run, do: Short.go()
        end
        """)
      ]

      graph = Graph.build(file_asts)

      call_targets =
        graph
        |> Graph.dependencies("MyApp.Caller")
        |> Enum.filter(&(&1.type == :call))
        |> Enum.map(& &1.target)

      assert "MyApp.LongName.Module" in call_targets
    end

    test "fully-qualified call still works without alias" do
      file_asts = [
        parse("lib/myapp/caller.ex", ~S"""
        defmodule MyApp.Caller do
          def run, do: MyApp.Runner.start()
        end
        """)
      ]

      graph = Graph.build(file_asts)

      call_targets =
        graph
        |> Graph.dependencies("MyApp.Caller")
        |> Enum.filter(&(&1.type == :call))
        |> Enum.map(& &1.target)

      assert "MyApp.Runner" in call_targets
    end

    test "unrecognized short form falls back to bare name" do
      # When a single-segment alias has no binding (no preceding
      # `alias`), keep prior behaviour: emit edge with the bare name.
      # Closure won't follow it (no matching module), but the edge
      # is preserved for any consumer that wants the raw signal.
      file_asts = [
        parse("lib/myapp/caller.ex", ~S"""
        defmodule MyApp.Caller do
          def run, do: SomeBareThing.go()
        end
        """)
      ]

      graph = Graph.build(file_asts)

      call_targets =
        graph
        |> Graph.dependencies("MyApp.Caller")
        |> Enum.filter(&(&1.type == :call))
        |> Enum.map(& &1.target)

      assert "SomeBareThing" in call_targets
    end
  end
end
