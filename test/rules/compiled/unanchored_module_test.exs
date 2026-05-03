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
end
