defmodule Archdo.Compiled.DiagramBlastRadiusTest do
  use ExUnit.Case, async: true

  alias Archdo.Compiled.Diagram

  # Synthetic Query.blast_radius/2 reports — only the
  # :transitive_dependents field is consumed by format_blast_radius.
  defp report(transitive), do: %{transitive_dependents: transitive}

  describe "format_blast_radius/2 — header and styling" do
    test "emits graph TD header and the changed-module style line" do
      svg = Diagram.format_blast_radius(report(%{}), MyApp.Changed)

      assert svg =~ "graph TD"
      assert svg =~ "MyApp_Changed[\"Changed · CHANGED\"]"
      assert svg =~ "style MyApp_Changed fill:#F44336"
    end
  end

  describe "format_blast_radius/2 — depth subgraphs" do
    test "renders one subgraph per depth, sorted ascending" do
      out =
        Diagram.format_blast_radius(
          report(%{2 => [MyApp.B], 1 => [MyApp.A]}),
          MyApp.Changed
        )

      idx_d1 = :binary.match(out, "subgraph depth_1") |> elem(0)
      idx_d2 = :binary.match(out, "subgraph depth_2") |> elem(0)
      assert idx_d1 < idx_d2, "depth 1 must render before depth 2"
    end

    test "labels the subgraph with the total module count" do
      mods = Enum.map(1..3, fn i -> Module.concat(MyApp, :"M#{i}") end)
      out = Diagram.format_blast_radius(report(%{1 => mods}), MyApp.Changed)
      assert out =~ "Depth 1 — 3 modules"
    end

    test "caps rendered nodes at 15 and emits an overflow indicator" do
      mods = Enum.map(1..20, fn i -> Module.concat(MyApp, :"M#{i}") end)
      out = Diagram.format_blast_radius(report(%{1 => mods}), MyApp.Changed)

      # Header still reflects the FULL count
      assert out =~ "Depth 1 — 20 modules"
      # Overflow line shows the extras (20 - 15 = 5)
      assert out =~ "more_1[\"... +5 more\"]"
    end

    test "no overflow indicator when count is at the cap" do
      mods = Enum.map(1..15, fn i -> Module.concat(MyApp, :"M#{i}") end)
      out = Diagram.format_blast_radius(report(%{1 => mods}), MyApp.Changed)
      refute out =~ "more_1["
    end
  end

  describe "format_blast_radius/2 — depth-1 connections" do
    test "draws an arrow from changed module to each depth-1 dependent" do
      out =
        Diagram.format_blast_radius(
          report(%{1 => [MyApp.A, MyApp.B]}),
          MyApp.Changed
        )

      assert out =~ "MyApp_Changed --> MyApp_A"
      assert out =~ "MyApp_Changed --> MyApp_B"
    end

    test "no connections when depth 1 is empty" do
      out =
        Diagram.format_blast_radius(
          report(%{2 => [MyApp.B]}),
          MyApp.Changed
        )

      refute out =~ "MyApp_Changed --> "
    end
  end

  describe "format_blast_radius/2 — depth color coding" do
    test "depth 1 uses orange (#FF9800), depth 2 amber (#FFC107), 3+ yellow (#FFEB3B)" do
      out =
        Diagram.format_blast_radius(
          report(%{1 => [MyApp.A], 2 => [MyApp.B], 3 => [MyApp.C], 5 => [MyApp.D]}),
          MyApp.Changed
        )

      assert out =~ "style MyApp_A fill:#FF9800"
      assert out =~ "style MyApp_B fill:#FFC107"
      assert out =~ "style MyApp_C fill:#FFEB3B"
      assert out =~ "style MyApp_D fill:#FFEB3B"
    end
  end
end
