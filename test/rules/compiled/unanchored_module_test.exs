defmodule Archdo.Rules.Compiled.UnanchoredModuleTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Compiled.UnanchoredModule

  describe "compute_closure/2 — pure forward BFS over a deps map" do
    test "single-anchor closure includes only directly-reachable modules" do
      deps = %{
        MyApp.Application => [MyApp.Boot, MyApp.Repo],
        MyApp.Boot => [MyApp.Helpers],
        MyApp.Repo => [],
        MyApp.Helpers => [],
        MyApp.Lonely => []
      }

      anchors = MapSet.new([MyApp.Application])
      closure = UnanchoredModule.compute_closure(deps, anchors)

      assert MapSet.equal?(
               closure,
               MapSet.new([MyApp.Application, MyApp.Boot, MyApp.Repo, MyApp.Helpers])
             )

      refute MapSet.member?(closure, MyApp.Lonely)
    end

    test "multi-anchor closure unions per-anchor reach" do
      deps = %{
        Anchor1 => [Mod.A],
        Anchor2 => [Mod.B],
        Mod.A => [],
        Mod.B => [],
        Mod.Orphan => []
      }

      closure = UnanchoredModule.compute_closure(deps, MapSet.new([Anchor1, Anchor2]))
      assert MapSet.equal?(closure, MapSet.new([Anchor1, Anchor2, Mod.A, Mod.B]))
    end

    test "cycle in deps doesn't loop forever" do
      deps = %{A => [B], B => [C], C => [A]}
      closure = UnanchoredModule.compute_closure(deps, MapSet.new([A]))
      assert MapSet.equal?(closure, MapSet.new([A, B, C]))
    end

    test "anchor with no deps still appears in closure" do
      deps = %{Solo => []}
      closure = UnanchoredModule.compute_closure(deps, MapSet.new([Solo]))
      assert MapSet.equal?(closure, MapSet.new([Solo]))
    end

    test "empty anchors returns empty closure" do
      deps = %{A => [B], B => []}
      closure = UnanchoredModule.compute_closure(deps, MapSet.new())
      assert MapSet.equal?(closure, MapSet.new())
    end

    test "module not in deps map is treated as having no outgoing edges" do
      deps = %{A => [B]}
      closure = UnanchoredModule.compute_closure(deps, MapSet.new([A]))
      assert MapSet.equal?(closure, MapSet.new([A, B]))
    end
  end

  describe "find_unanchored/2 — pure" do
    test "returns modules in the graph not in the anchor closure" do
      deps = %{
        MyApp.Application => [MyApp.Boot],
        MyApp.Boot => [],
        MyApp.OrphanA => [],
        MyApp.OrphanB => []
      }

      anchors = MapSet.new([MyApp.Application])

      assert UnanchoredModule.find_unanchored(deps, anchors) ==
               [MyApp.OrphanA, MyApp.OrphanB] |> Enum.sort()
    end

    test "no orphans → empty list" do
      deps = %{Anchor => [Reachable], Reachable => []}
      assert UnanchoredModule.find_unanchored(deps, MapSet.new([Anchor])) == []
    end

    test "all modules orphan when anchors set is empty" do
      deps = %{A => [], B => [], C => []}
      assert UnanchoredModule.find_unanchored(deps, MapSet.new()) == [A, B, C]
    end
  end

  describe "id/0 and description/0" do
    test "rule id is 1.26" do
      assert UnanchoredModule.id() == "1.26"
    end

    test "description distinguishes from CE-30 (AST) and 1.25 (orphan)" do
      desc = UnanchoredModule.description()
      assert desc =~ "compiled" or desc =~ "Compiled"
      assert desc =~ "anchor"
    end
  end

  describe "analyze_compiled/1 (without anchors in opts)" do
    test "returns empty list — rule is a no-op without anchor data" do
      # When called via the legacy /1 dispatch (no opts), the rule cannot
      # do anchor-reachability and returns empty rather than crashing.
      assert UnanchoredModule.analyze_compiled(%{}) == []
    end
  end

  describe "library mode — public modules are auto-anchored" do
    # In a library project, every public module (not @moduledoc false) is
    # part of the public API. Without this carve-out, every public module
    # flags as unreachable because library consumers — the actual callers —
    # aren't visible to the analyzer. Same shape as CE-30's library handling.
    test "find_unanchored/2 with library publics included treats them as anchors" do
      deps = %{
        MyLib.PublicAPI => [MyLib.Internal],
        MyLib.Internal => [],
        MyLib.OtherPublicAPI => [],
        MyLib.TrulyOrphan => []
      }

      # Simulate library mode: AST anchors empty, but public modules
      # treated as anchors.
      ast_anchors = MapSet.new()
      library_publics = MapSet.new([MyLib.PublicAPI, MyLib.OtherPublicAPI])
      combined = MapSet.union(ast_anchors, library_publics)

      assert UnanchoredModule.find_unanchored(deps, combined) == [MyLib.TrulyOrphan]
    end

    test "in non-library mode, public modules without anchors stay orphan" do
      deps = %{MyApp.PublicAPI => [], MyApp.Other => []}

      # No library carve-out — public modules without explicit anchors
      # remain unanchored.
      assert UnanchoredModule.find_unanchored(deps, MapSet.new()) ==
               [MyApp.Other, MyApp.PublicAPI]
    end
  end

  describe "behaviour_implementor_anchors/1 — F3 closure seeding" do
    # Bug surfaced during PS investigation: behaviour-implementors were
    # excluded from being FLAGGED (they cannot be reached statically) but
    # they were NOT added to the anchor closure. So if a behaviour-impl
    # module (e.g. Bandit.Adapter, impl Plug.Conn.Adapter) is the SOLE
    # caller of an internal helper (Bandit.Headers), the helper is
    # unreachable from the anchor walk and 1.26 falsely flags it.
    #
    # Fix: also seed the closure with behaviour-implementors. They're
    # effectively anchored by the framework that owns the behaviour, so
    # their outgoing edges should propagate.

    test "extracts module atoms from compiled-graph modules with @behaviour" do
      modules = %{
        Mod.PlugAdapter => %{behaviours: [Plug.Conn.Adapter], exports: []},
        Mod.Plain => %{behaviours: [], exports: []},
        Mod.GenServerImpl => %{behaviours: [GenServer], exports: []}
      }

      result = UnanchoredModule.behaviour_implementor_anchors(modules)
      assert MapSet.equal?(result, MapSet.new([Mod.PlugAdapter, Mod.GenServerImpl]))
    end

    test "returns empty set when no module declares any behaviour" do
      modules = %{
        Mod.A => %{behaviours: [], exports: []},
        Mod.B => %{behaviours: [], exports: []}
      }

      assert UnanchoredModule.behaviour_implementor_anchors(modules) == MapSet.new()
    end

    test "behaviour-implementor's outgoing edges propagate through closure" do
      # End-to-end: Adapter (behaviour impl) → Headers. With Adapter in the
      # closure seed (alongside library_publics), Headers becomes reachable.
      base = %{
        Bandit => [Bandit.Adapter],
        Bandit.Adapter => [Bandit.Headers],
        Bandit.Headers => [],
        Bandit.Orphan => []
      }

      modules_meta = %{
        Bandit => %{behaviours: [], exports: []},
        Bandit.Adapter => %{behaviours: [Plug.Conn.Adapter], exports: []},
        Bandit.Headers => %{behaviours: [], exports: []},
        Bandit.Orphan => %{behaviours: [], exports: []}
      }

      library_publics = MapSet.new([Bandit])

      behav_anchors = UnanchoredModule.behaviour_implementor_anchors(modules_meta)
      combined = MapSet.union(library_publics, behav_anchors)

      # Without behav anchors: Headers unreachable (Adapter not in closure
      # because @moduledoc false, public Bandit doesn't directly reach Headers).
      # With behav anchors: Adapter is seeded, its edge to Headers traversed.
      assert UnanchoredModule.find_unanchored(base, combined) == [Bandit.Orphan]
    end
  end

  describe "merge_macro_emit_edges/2 — M-fp-F1 wiring" do
    # M-fp-F1: virtual edges reconstructed from `defmacro` bodies. A library
    # macro that quotes a sibling module reference (Commanded.Commands.Router
    # → Commanded.Commands.Dispatcher pattern) gets a virtual edge here so
    # the closure walk can reach the otherwise-orphan module.

    test "merges macro-emit targets into existing deps map" do
      base = %{
        Mod.A => [Mod.B],
        Mod.B => []
      }

      macro_edges = %{
        Mod.A => [Mod.C, Mod.D]
      }

      merged = UnanchoredModule.merge_macro_emit_edges(base, macro_edges)
      assert Enum.sort(merged[Mod.A]) == [Mod.B, Mod.C, Mod.D]
      assert merged[Mod.B] == []
    end

    test "macro-emit edges to modules not in base map are still added" do
      # Source module IS in base; targets may or may not be — both work.
      base = %{Mod.A => []}
      macro_edges = %{Mod.A => [Mod.NewTarget]}

      merged = UnanchoredModule.merge_macro_emit_edges(base, macro_edges)
      assert Mod.NewTarget in merged[Mod.A]
    end

    test "deduplicates when macro-emit overlaps with base edges" do
      base = %{Mod.A => [Mod.Shared]}
      macro_edges = %{Mod.A => [Mod.Shared, Mod.Other]}

      merged = UnanchoredModule.merge_macro_emit_edges(base, macro_edges)
      assert Enum.count(merged[Mod.A], &(&1 == Mod.Shared)) == 1
      assert Mod.Other in merged[Mod.A]
    end

    test "modules with no macro-emit edges are unchanged" do
      base = %{Mod.A => [], Mod.B => [Mod.C]}
      macro_edges = %{}

      merged = UnanchoredModule.merge_macro_emit_edges(base, macro_edges)
      assert merged == base
    end

    test "macro-emit edges anchor an otherwise-orphan module via the closure" do
      # Integration: Commanded shape — Router declares the macro, Dispatcher
      # is the emit-target. Without macro-emit edges, Dispatcher is orphan;
      # with them, Router → Dispatcher and the closure reaches Dispatcher.
      base = %{
        Commanded.Commands.Router => [],
        Commanded.Commands.Dispatcher => [],
        Commanded.OrphanReally => []
      }

      macro_edges = %{
        Commanded.Commands.Router => [Commanded.Commands.Dispatcher]
      }

      merged = UnanchoredModule.merge_macro_emit_edges(base, macro_edges)
      anchors = MapSet.new([Commanded.Commands.Router])

      # Without merge: Dispatcher would appear as unanchored
      assert UnanchoredModule.find_unanchored(base, anchors) ==
               [Commanded.Commands.Dispatcher, Commanded.OrphanReally]

      # With merge: Dispatcher is reached; OrphanReally still flags.
      assert UnanchoredModule.find_unanchored(merged, anchors) ==
               [Commanded.OrphanReally]
    end
  end

  describe "build_diagnostic/1 — fix-text guidance" do
    # M-fp-E2: macro-edge audit on Commanded showed that
    # `Commanded.Commands.Router`'s `dispatch_to_aggregate/3` macro emits
    # the call to `Commanded.Commands.Dispatcher` into the CONSUMER's
    # compiled module — the library's own BEAM has zero edges to Dispatcher
    # (`:beam_lib.chunks/2` confirms). When 1.26 is run on a library scanned
    # in isolation, that macro pattern manifests as an unreachable
    # `@moduledoc false` module. The @archdo_anchor Fix MUST surface this
    # specific failure mode in its detail text — generic "apply/3 from
    # config" / ":erpc" guidance doesn't lead a user toward the fix.
    test "@archdo_anchor Fix.detail explicitly mentions macro-dispatch into consumer modules" do
      diag = UnanchoredModule.build_diagnostic(MyApp.OrphanMod)

      marker_fix =
        Enum.find(diag.alternatives, fn fix ->
          fix.summary =~ "@archdo_anchor"
        end)

      assert marker_fix, "expected an @archdo_anchor alternative fix"

      assert marker_fix.detail =~ "macro",
             "fix detail should call out the macro-dispatch pattern; got: #{marker_fix.detail}"
    end

    test "diagnostic message acknowledges the macro-edge gap honestly" do
      # The pre-E2 message claimed "the compiled call graph captures all
      # macro-injected edges, so a module appearing here is NOT a macro
      # false positive". The Commanded audit disproves this: macros that
      # emit calls into the CONSUMER's compiled module are invisible to
      # library-scope compiled analysis. Soften the claim to "strong
      # signal but not absolute" — and direct readers to @archdo_anchor.
      diag = UnanchoredModule.build_diagnostic(MyApp.OrphanMod)

      refute diag.message =~ "NOT a macro false positive",
             "message should not assert macro-FP-immunity; got: #{diag.message}"
    end
  end

  describe "behaviour-implementor anchoring (M-fp-D10)" do
    # A module that declares `@behaviour SomeBehaviour` is reached via
    # behaviour-callback dispatch by the parent library/framework. Without
    # this, modules like Bandit.Adapter (impl Plug.Conn.Adapter) flag as
    # "unreachable" because their callers reach via apply(mod, callback, ...)
    # which static analysis can't track.
    test "behaviour-implementor anchors merge into closure same as library publics" do
      deps = %{
        MyApp.Internal => [],
        MyApp.PlugAdapter => [],
        MyApp.GenServerImpl => [],
        MyApp.TrulyOrphan => []
      }

      ast_anchors = MapSet.new()
      library_publics = MapSet.new()
      behaviour_implementors = MapSet.new([MyApp.PlugAdapter, MyApp.GenServerImpl])

      combined =
        ast_anchors
        |> MapSet.union(library_publics)
        |> MapSet.union(behaviour_implementors)

      assert UnanchoredModule.find_unanchored(deps, combined) ==
               [MyApp.Internal, MyApp.TrulyOrphan]
    end
  end
end
