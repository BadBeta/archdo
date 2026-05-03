defmodule Archdo.CleanupPassTest do
  use ExUnit.Case, async: true

  alias Archdo.CleanupPass

  describe "pass_for/1" do
    test "returns pass for a new rule with cleanup_pass/0 callback (5.50 → pass 6)" do
      assert CleanupPass.pass_for("5.50") == 6
    end

    test "returns pass for 5.51 (apply-from-input → pass 6)" do
      assert CleanupPass.pass_for("5.51") == 6
    end

    test "returns pass for 5.52 (stacktrace_in_response → pass 5)" do
      assert CleanupPass.pass_for("5.52") == 5
    end

    test "returns pass for 5.53 (io_inspect_in_lib → pass 5)" do
      assert CleanupPass.pass_for("5.53") == 5
    end

    test "returns pass for 5.54 (secret_struct_inspect → pass 5)" do
      assert CleanupPass.pass_for("5.54") == 5
    end

    test "returns pass for 5.55 (async_drops_logger_metadata → pass 13)" do
      assert CleanupPass.pass_for("5.55") == 13
    end

    test "returns pass for 1.20 (atom_at_boundary → pass 3)" do
      assert CleanupPass.pass_for("1.20") == 3
    end

    test "returns pass for 1.21 (raw_map_in_domain → pass 2)" do
      assert CleanupPass.pass_for("1.21") == 2
    end

    test "returns pass for 1.22 (internal_struct_as_encoder → pass 10)" do
      assert CleanupPass.pass_for("1.22") == 10
    end

    test "returns pass for 8.9 (event_payload_unversioned → pass 10)" do
      assert CleanupPass.pass_for("8.9") == 10
    end

    test "returns pass for 3.2 (scattered_config → pass 4)" do
      assert CleanupPass.pass_for("3.2") == 4
    end

    test "returns nil for unmapped rule id" do
      assert CleanupPass.pass_for("99.99") == nil
    end

    test "returns pass for selected existing rules — 1.2 (cross_boundary_call → pass 12)" do
      assert CleanupPass.pass_for("1.2") == 12
    end

    test "returns pass for 5.1 (unsupervised_process → pass 7)" do
      assert CleanupPass.pass_for("5.1") == 7
    end
  end

  describe "rules_for/2" do
    test "returns rules tagged with a specific pass" do
      rules = [
        Archdo.Rules.Module.UnsafeDeserialization,
        Archdo.Rules.Module.DynamicApplyFromInput,
        Archdo.Rules.Module.IoInspectInLib
      ]

      pass_6 = CleanupPass.rules_for(6, rules)

      assert Archdo.Rules.Module.UnsafeDeserialization in pass_6
      assert Archdo.Rules.Module.DynamicApplyFromInput in pass_6
      refute Archdo.Rules.Module.IoInspectInLib in pass_6
    end

    test "returns empty list when no rules match the pass" do
      assert CleanupPass.rules_for(99, [Archdo.Rules.Module.UnsafeDeserialization]) == []
    end
  end

  describe "all_passes/0" do
    test "returns the canonical 14-element list" do
      assert CleanupPass.all_passes() == Enum.to_list(1..14)
    end
  end

  describe "pass_label/1" do
    test "returns a human-readable label for each pass" do
      assert CleanupPass.pass_label(2) =~ "Boundary"
      assert CleanupPass.pass_label(5) =~ "Secret"
      assert CleanupPass.pass_label(6) =~ "Deserialization"
      assert CleanupPass.pass_label(7) =~ "OTP"
      assert CleanupPass.pass_label(13) =~ "Observability"
    end

    test "raises on invalid pass" do
      assert_raise FunctionClauseError, fn -> CleanupPass.pass_label(15) end
    end
  end

  describe "rule callback integration" do
    test "new rules implement cleanup_pass/0" do
      assert Archdo.Rules.Module.UnsafeDeserialization.cleanup_pass() == 6
      assert Archdo.Rules.Module.DynamicApplyFromInput.cleanup_pass() == 6
      assert Archdo.Rules.Module.StacktraceInResponse.cleanup_pass() == 5
      assert Archdo.Rules.Module.IoInspectInLib.cleanup_pass() == 5
      assert Archdo.Rules.Module.SecretStructInspect.cleanup_pass() == 5
      assert Archdo.Rules.OTP.AsyncDropsLoggerMetadata.cleanup_pass() == 13
      assert Archdo.Rules.Boundary.AtomAtBoundary.cleanup_pass() == 3
      assert Archdo.Rules.Boundary.RawMapInDomain.cleanup_pass() == 2
      assert Archdo.Rules.Boundary.InternalStructAsEncoder.cleanup_pass() == 10
      assert Archdo.Rules.EventSourcing.EventPayloadUnversioned.cleanup_pass() == 10
    end

    test "Archdo.Rule.cleanup_pass_of/1 falls back to mapping when callback absent" do
      # A rule without the callback uses the curated mapping
      assert Archdo.Rule.cleanup_pass_of(Archdo.Rules.Module.ScatteredConfig) == 4
    end

    test "Archdo.Rule.cleanup_pass_of/1 prefers the callback when present" do
      assert Archdo.Rule.cleanup_pass_of(Archdo.Rules.Module.UnsafeDeserialization) == 6
    end

    test "Archdo.Rule.cleanup_pass_of/1 returns nil for fully untagged rules" do
      # Pick a rule that isn't tagged in either place — e.g. a CE rule
      # the cleanup guide doesn't address (project-Archdo-unique architectural).
      result = Archdo.Rule.cleanup_pass_of(Archdo.Rules.CE.BlackboxQuadrant)
      # nil OR a deliberate mapping if we choose to add one — current expectation: nil
      assert result == nil
    end
  end
end
