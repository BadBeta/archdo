defmodule Archdo.CleanupPass.CoverageTest do
  use ExUnit.Case, async: true

  alias Archdo.CleanupPass.Coverage

  describe "compute/2" do
    test "returns a map keyed 1..14" do
      result = Coverage.compute([], [])
      assert Map.keys(result) |> Enum.sort() == Enum.to_list(1..14)
    end

    test "each pass entry has rule_count and finding_count keys" do
      result = Coverage.compute([], [])

      for pass <- 1..14 do
        entry = Map.fetch!(result, pass)
        assert is_map(entry)
        assert is_integer(entry.rule_count)
        assert is_integer(entry.finding_count)
      end
    end

    test "rule_count counts rules tagged with each pass" do
      rules = [
        Archdo.Rules.Module.UnsafeDeserialization,
        Archdo.Rules.Module.DynamicApplyFromInput,
        Archdo.Rules.Boundary.AtomAtBoundary
      ]

      result = Coverage.compute(rules, [])

      assert result[6].rule_count == 2
      assert result[3].rule_count == 1
      assert result[2].rule_count == 0
    end

    test "finding_count counts diagnostics whose rule_id maps to each pass" do
      diags = [
        diag("5.50"),
        diag("5.50"),
        diag("5.51"),
        diag("1.20"),
        diag("9.99")
      ]

      result = Coverage.compute([], diags)

      # 5.50 + 5.51 → pass 6 → 3 findings
      assert result[6].finding_count == 3
      # 1.20 → pass 3 → 1 finding
      assert result[3].finding_count == 1
      # 9.99 unmapped → no pass increment
      assert result[2].finding_count == 0
    end
  end

  describe "format/1" do
    test "produces a 14-row table" do
      result = Coverage.compute([], [])
      output = Coverage.format(result)

      assert is_binary(output)
      # Each pass should appear (zero-padded for column alignment)
      for pass <- 1..14 do
        padded = String.pad_leading(Integer.to_string(pass), 2, "0")
        assert output =~ "Pass #{padded}"
      end
    end

    test "includes pass labels" do
      result = Coverage.compute([], [])
      output = Coverage.format(result)
      assert output =~ "Boundary"
      assert output =~ "Atom"
      assert output =~ "OTP"
    end
  end

  defp diag(rule_id) do
    %Archdo.Diagnostic{
      rule_id: rule_id,
      severity: :warning,
      title: "test",
      message: "test",
      why: "test",
      file: "lib/test.ex",
      line: 1
    }
  end
end
