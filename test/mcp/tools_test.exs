defmodule Archdo.Mcp.ToolsTest do
  use ExUnit.Case, async: true

  alias Archdo.Mcp.Tools.{
    AnalyzeFile,
    AnalyzePaths,
    Diff,
    ExplainFinding,
    ExplainRule,
    Fix,
    Health,
    ListRules,
    PerfAudit,
    Suggest
  }

  describe "archdo_health" do
    test "returns health summary with grade" do
      {:ok, result} = Health.call(%{"paths" => ["lib"]})

      assert is_map(result.summary)
      assert is_integer(result.summary.total)
      assert result.summary.total > 0
      assert result.health_grade in ["A+", "A", "B", "C", "D"]
      assert is_list(result.top_rules)
      assert length(result.top_rules) <= 10
    end
  end

  describe "archdo_analyze_paths" do
    test "returns diagnostics for a path" do
      {:ok, result} = AnalyzePaths.call(%{"paths" => ["lib/archdo/ast.ex"]})

      assert is_map(result.summary)
      assert is_list(result.diagnostics)
    end

    test "respects only filter" do
      {:ok, result} =
        AnalyzePaths.call(%{
          "paths" => ["lib/archdo/ast.ex"],
          "only" => ["2.1"]
        })

      Enum.each(result.diagnostics, fn d ->
        assert d.rule_id == "2.1"
      end)
    end

    test "returns error for missing paths" do
      assert {:error, _} = AnalyzePaths.call(%{})
    end
  end

  describe "archdo_analyze_file" do
    test "analyzes a real file" do
      {:ok, result} =
        AnalyzeFile.call(%{
          "file" => "lib/archdo/diagnostic.ex",
          "content" => File.read!("lib/archdo/diagnostic.ex")
        })

      assert is_map(result.summary)
      assert is_list(result.diagnostics)
    end
  end

  describe "archdo_diff" do
    test "analyzes changed files since ref" do
      result = Diff.call(%{"ref" => "HEAD", "paths" => ["lib"]})

      case result do
        {:ok, data} ->
          assert data.ref == "HEAD"
          assert is_integer(data.changed_files)

        {:error, _reason} ->
          # git not available or no commits — acceptable in CI
          :ok
      end
    end
  end

  describe "archdo_perf_audit" do
    test "returns performance findings grouped by impact" do
      {:ok, result} = PerfAudit.call(%{"paths" => ["lib"]})

      assert is_integer(result.total)
      assert is_map(result.by_impact)
      assert is_map(result.summary)
      assert Map.has_key?(result.summary, :high)
      assert Map.has_key?(result.summary, :medium)
      assert Map.has_key?(result.summary, :low)
    end
  end

  describe "archdo_suggest" do
    test "returns suggestions for a GenServer file" do
      {:ok, result} = Suggest.call(%{"file" => "lib/archdo/mcp/server.ex"})

      assert result.file_type in [:genserver, :module]
      assert is_list(result.suggestions)
      assert result.suggestions != []
    end

    test "returns suggestions for a test file" do
      path = Path.expand("test/runner_test.exs")
      {:ok, result} = Suggest.call(%{"file" => path})

      assert result.file_type == :test
      assert is_list(result.suggestions)
    end

    test "returns error for missing file" do
      assert {:error, _} = Suggest.call(%{"file" => "nonexistent.ex"})
    end
  end

  describe "archdo_explain_finding" do
    test "returns finding at specified line" do
      {:ok, result} =
        ExplainFinding.call(%{
          "file" => "lib/archdo/ast.ex",
          "line" => 1
        })

      assert result.file == "lib/archdo/ast.ex"
      assert is_binary(result.code_context) or is_nil(result.code_context)
    end

    test "returns error for missing file" do
      assert {:error, _} = ExplainFinding.call(%{"file" => "nonexistent.ex", "line" => 1})
    end
  end

  describe "archdo_fix" do
    test "generates fix suggestions for a file" do
      {:ok, result} = Fix.call(%{"file" => "lib/archdo/ast.ex"})

      assert is_integer(result.fixable_count)
      assert is_integer(result.total_findings)
      assert is_list(result.fixes)
    end

    test "returns error for missing file" do
      assert {:error, _} = Fix.call(%{"file" => "nonexistent.ex"})
    end

    test "generates fixes for specific rule" do
      {:ok, result} =
        Fix.call(%{
          "file" => "lib/archdo/ast.ex",
          "rule_id" => "4.27"
        })

      assert is_list(result.fixes)

      Enum.each(result.fixes, fn fix ->
        assert fix.rule_id == "4.27"
      end)
    end
  end

  describe "archdo_explain_rule" do
    test "returns rule details" do
      {:ok, result} = ExplainRule.call(%{"id" => "6.50"})

      assert result.id == "6.50"
      assert is_binary(result.description)
    end

    test "returns error for unknown rule" do
      result = ExplainRule.call(%{"id" => "99.99"})

      assert {:error, msg} = result
      assert msg =~ "no rule found"
    end
  end

  describe "archdo_list_rules" do
    test "returns all rules" do
      {:ok, result} = ListRules.call(%{})

      assert result.count > 150
      assert is_list(result.rules)

      Enum.each(result.rules, fn rule ->
        assert Map.has_key?(rule, :id)
        assert Map.has_key?(rule, :description)
      end)
    end

    test "filters by category" do
      {:ok, result} = ListRules.call(%{"category" => "otp"})

      assert result.count > 0

      Enum.each(result.rules, fn rule ->
        assert String.starts_with?(rule.id, "5.")
      end)
    end
  end
end
