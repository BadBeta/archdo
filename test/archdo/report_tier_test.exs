defmodule Archdo.ReportTierTest do
  use ExUnit.Case, async: true

  alias Archdo.ReportTier

  describe "severities_for/1" do
    test "critical → [:error]" do
      assert ReportTier.severities_for(:critical) == [:error]
    end

    test "architectural → [:error, :warning]" do
      assert ReportTier.severities_for(:architectural) == [:error, :warning]
    end

    test "quality → [:info, :nitpick]" do
      assert ReportTier.severities_for(:quality) == [:info, :nitpick]
    end

    test "all → all four severities" do
      assert ReportTier.severities_for(:all) == [:error, :warning, :info, :nitpick]
    end
  end

  describe "filter/2" do
    setup do
      d_error = build_diag(:error, "1.20")
      d_warn = build_diag(:warning, "5.50")
      d_info = build_diag(:info, "6.49")
      d_nitpick = build_diag(:nitpick, "6.33")

      %{
        diagnostics: [d_error, d_warn, d_info, d_nitpick],
        d_error: d_error,
        d_warn: d_warn,
        d_info: d_info,
        d_nitpick: d_nitpick
      }
    end

    test "critical includes error only", %{diagnostics: ds, d_error: d_error} do
      assert ReportTier.filter(ds, :critical) == [d_error]
    end

    test "architectural includes error + warning",
         %{diagnostics: ds, d_error: d_error, d_warn: d_warn} do
      assert ReportTier.filter(ds, :architectural) == [d_error, d_warn]
    end

    test "quality includes info + nitpick",
         %{diagnostics: ds, d_info: d_info, d_nitpick: d_nitpick} do
      assert ReportTier.filter(ds, :quality) == [d_info, d_nitpick]
    end

    test "all returns the input unchanged", %{diagnostics: ds} do
      assert ReportTier.filter(ds, :all) == ds
    end

    test "nil tier returns the input unchanged", %{diagnostics: ds} do
      assert ReportTier.filter(ds, nil) == ds
    end
  end

  describe "parse/1" do
    test "parses each known label" do
      assert ReportTier.parse("critical") == {:ok, :critical}
      assert ReportTier.parse("architectural") == {:ok, :architectural}
      assert ReportTier.parse("quality") == {:ok, :quality}
      assert ReportTier.parse("all") == {:ok, :all}
    end

    test "rejects unknown labels" do
      assert {:error, _} = ReportTier.parse("blocker")
      assert {:error, _} = ReportTier.parse("")
    end
  end

  describe "all_tiers/0" do
    test "returns the canonical 4-element list" do
      assert ReportTier.all_tiers() == [:critical, :architectural, :quality, :all]
    end
  end

  defp build_diag(severity, rule_id) do
    %Archdo.Diagnostic{
      rule_id: rule_id,
      severity: severity,
      title: "test",
      message: "test",
      why: "test",
      file: "lib/test.ex",
      line: 1
    }
  end
end
