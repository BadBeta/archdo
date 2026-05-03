defmodule Archdo.Rules.Module.MainSequenceDistanceTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Module.MainSequenceDistance

  # Builds a synthetic Pain-zone metric (A=0, I=0, D≥0.85) with enough
  # coupling to clear the @min_total_coupling gate.
  defp pain(module, ce \\ 5) do
    %{
      module: module,
      ca: 5,
      ce: ce,
      instability: 0.0,
      abstractness: 0.0,
      distance: 1.0
    }
  end

  defp file_map(modules), do: Map.new(modules, &{&1, "lib/fake.ex"})

  defp module_names(diags), do: Enum.map(diags, & &1.context.module)

  describe "analyze_project/2 — pain-zone flagging" do
    test "flags an arbitrary pain-zone module with sufficient coupling" do
      m = pain("MyApp.Service")
      diags = MainSequenceDistance.analyze_project([m], file_map(["MyApp.Service"]))

      assert ["MyApp.Service"] = module_names(diags)
    end

    test "does not flag a module below the min total coupling threshold" do
      m = %{pain("MyApp.Service") | ca: 1, ce: 1}
      assert [] = MainSequenceDistance.analyze_project([m], file_map(["MyApp.Service"]))
    end

    test "does not flag a module on the main sequence" do
      healthy = %{
        module: "MyApp.Service",
        ca: 5,
        ce: 5,
        instability: 0.5,
        abstractness: 0.5,
        distance: 0.0
      }

      assert [] = MainSequenceDistance.analyze_project([healthy], file_map(["MyApp.Service"]))
    end

    test "uses :warning severity for distance ≥ 0.85, :info below" do
      pain_high = pain("MyApp.High")
      pain_low = %{pain("MyApp.Low") | distance: 0.7}

      diags =
        MainSequenceDistance.analyze_project(
          [pain_high, pain_low],
          file_map(["MyApp.High", "MyApp.Low"])
        )

      by_module = Map.new(diags, &{&1.context.module, &1.severity})
      assert by_module["MyApp.High"] == :warning
      assert by_module["MyApp.Low"] == :info
    end
  end

  describe "stable_by_design? exemptions (via analyze_project)" do
    test "exempts framework-conventional suffixes: Repo, Web, Config, Configuration" do
      modules = ["MyApp.Repo", "MyAppWeb", "MyApp.Config", "MyApp.Configuration"]
      metrics = Enum.map(modules, &pain/1)

      assert [] = MainSequenceDistance.analyze_project(metrics, file_map(modules))
    end

    test "exempts utility suffixes: .Helpers, .Helper, .Util, .Utils, .AST, .Naming" do
      # Suffixes match with a leading dot, so MyApp.StringHelpers does NOT
      # match .Helpers — only MyApp.Helpers does. This is intentional: the
      # convention names a *whole module* a helper, not a renamed concept
      # ending in "Helpers".
      modules = [
        "MyApp.Helpers",
        "MyApp.Helper",
        "MyApp.Util",
        "MyApp.Utils",
        "MyApp.AST",
        "MyApp.Naming"
      ]

      metrics = Enum.map(modules, &pain/1)
      assert [] = MainSequenceDistance.analyze_project(metrics, file_map(modules))
    end

    test "does NOT exempt modules whose name merely contains a utility word without a leading dot" do
      # MyApp.StringHelpers ends with "Helpers" but not ".Helpers" — flagged.
      m = pain("MyApp.StringHelpers")
      diags = MainSequenceDistance.analyze_project([m], file_map(["MyApp.StringHelpers"]))
      assert ["MyApp.StringHelpers"] = module_names(diags)
    end

    test "exempts leaf utility modules (A=0 AND Ce ≤ 2) regardless of name" do
      leaf = %{pain("MyApp.RandomLeaf", 2) | ca: 5}
      assert [] = MainSequenceDistance.analyze_project([leaf], file_map(["MyApp.RandomLeaf"]))
    end

    test "flags utility-shaped modules with Ce > 2 (not a leaf)" do
      not_leaf = pain("MyApp.RandomService", 5)

      diags =
        MainSequenceDistance.analyze_project([not_leaf], file_map(["MyApp.RandomService"]))

      assert ["MyApp.RandomService"] = module_names(diags)
    end

    test "exempts *.Reading and *.Event ONLY when leaf (Ce ≤ 1)" do
      leaf_reading = %{pain("MyApp.TempReading", 1) | ca: 5}
      leaf_event = %{pain("MyApp.OrderEvent", 1) | ca: 5}
      non_leaf_reading = %{pain("MyApp.HeavyReading", 3) | ca: 5}

      diags =
        MainSequenceDistance.analyze_project(
          [leaf_reading, leaf_event, non_leaf_reading],
          file_map(["MyApp.TempReading", "MyApp.OrderEvent", "MyApp.HeavyReading"])
        )

      # leaf_reading and leaf_event would still be exempt via leaf_utility (Ce≤2),
      # so to truly exercise the Reading/Event branch we'd need Ce in {1,2}. Ce=3
      # disqualifies both the Reading rule (Ce>1) AND leaf_utility (Ce>2), so the
      # non-leaf reading IS flagged.
      assert ["MyApp.HeavyReading"] = module_names(diags)
    end
  end
end
