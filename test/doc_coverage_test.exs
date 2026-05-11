defmodule Archdo.DocCoverageTest do
  use ExUnit.Case, async: true

  alias Archdo.DocCoverage

  describe "registered_rule_ids/0" do
    test "returns every unique rule id from the registries" do
      ids = DocCoverage.registered_rule_ids()
      assert is_list(ids)
      assert length(ids) > 200
      # Sample known-stable rules
      assert "1.1" in ids
      assert "5.50" in ids
      assert "CE-50" in ids
    end

    test "ids are unique" do
      ids = DocCoverage.registered_rule_ids()
      assert length(ids) == length(Enum.uniq(ids))
    end
  end

  describe "documented_rule_ids/1" do
    test "extracts rule ids from `### X.Y Title` headings in a markdown file" do
      content = """
      # Doc

      ## Section
      ### 1.1 Foo
      Some text
      ### CE-50 Bar
      More text
      ### Not a rule heading
      ### 6.50 Baz
      """

      ids = DocCoverage.documented_rule_ids(content)
      assert "1.1" in ids
      assert "CE-50" in ids
      assert "6.50" in ids
    end

    test "ignores subsection headers that aren't real rule ids" do
      # The doc uses `### 5A. GenServer Hygiene`, `### 6A. Cohesion`,
      # etc. as category subdividers. Those should NOT be reported
      # as stale rules. Only real id shapes (1.1, CE-50, SM-A) count.
      content = """
      ### 5A. GenServer Hygiene
      ### 5.50 Real rule
      ### 6A. Cohesion (subsection)
      ### CE-50 Real CE rule
      ### Building-Block (label, not an id)
      ### Plain prose heading
      """

      ids = DocCoverage.documented_rule_ids(content)
      assert "5.50" in ids
      assert "CE-50" in ids
      refute "5A." in ids
      refute "6A." in ids
      refute "Building-Block" in ids
    end
  end

  describe "audit/2 — gap analysis" do
    test "returns empty missing/stale when registry == doc" do
      registry = ["1.1", "5.50", "CE-50"]
      doc = ["1.1", "5.50", "CE-50"]
      assert {:ok, %{missing: [], stale: []}} = DocCoverage.audit(registry, doc)
    end

    test "flags rules in registry but not in doc as :missing" do
      registry = ["1.1", "5.50", "5.99"]
      doc = ["1.1", "5.50"]
      assert {:gap, %{missing: ["5.99"], stale: []}} = DocCoverage.audit(registry, doc)
    end

    test "flags rules in doc but not in registry as :stale" do
      registry = ["1.1"]
      doc = ["1.1", "9.99"]
      assert {:gap, %{missing: [], stale: ["9.99"]}} = DocCoverage.audit(registry, doc)
    end

    test "missing and stale are sorted lexicographically" do
      registry = ["6.10", "6.2", "6.1"]
      doc = ["6.1", "9.zzz", "9.aaa"]

      assert {:gap, %{missing: ["6.10", "6.2"], stale: ["9.aaa", "9.zzz"]}} =
               DocCoverage.audit(registry, doc)
    end
  end

  describe "ARCHITECTURE_RULES.md regression guard" do
    # The repo-level guarantee: as we work through M-Doc-RR-2 .. M-Doc-RR-8
    # the baseline shrinks. This test fails when:
    #   - a rule is missing from the doc AND not listed in the baseline
    #     (someone added a rule without docs)
    #   - the doc references a rule no longer in the registry (stale)
    test "ARCHITECTURE_RULES.md is in sync with the rule registry (with baselines)" do
      registry = DocCoverage.registered_rule_ids()

      doc =
        "ARCHITECTURE_RULES.md"
        |> File.read!()
        |> DocCoverage.documented_rule_ids()

      missing_baseline = load_baseline("priv/doc_coverage_baseline.txt")
      stale_baseline = load_baseline("priv/doc_coverage_stale_baseline.txt")

      assert :ok =
               DocCoverage.audit_against_baseline(
                 registry,
                 doc,
                 missing_baseline,
                 stale_baseline
               )
    end
  end

  defp load_baseline(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.reject(&String.starts_with?(&1, "#"))
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      {:error, _} ->
        []
    end
  end

  describe "audit_against_baseline/3 — regression guard" do
    # The baseline lists the IDs we acknowledge as currently-undocumented.
    # As rules get documented, their IDs are removed from the baseline.
    # The audit fails when:
    #   - a rule is missing from the doc AND not in the baseline
    #     (someone added a rule without docs)
    #   - any rule is :stale (doc references a non-existent rule)

    test "passes when missing rules are exactly the baseline" do
      registry = ["1.1", "5.99", "6.99"]
      doc = ["1.1"]
      baseline = ["5.99", "6.99"]

      assert :ok = DocCoverage.audit_against_baseline(registry, doc, baseline)
    end

    test "passes when missing rules are a subset of the baseline (some got documented)" do
      registry = ["1.1", "5.99", "6.99"]
      doc = ["1.1", "5.99"]
      baseline = ["5.99", "6.99"]

      assert :ok = DocCoverage.audit_against_baseline(registry, doc, baseline)
    end

    test "fails when a missing rule is NOT in the baseline (regression)" do
      registry = ["1.1", "5.99", "6.99", "7.99"]
      doc = ["1.1"]
      baseline = ["5.99", "6.99"]

      assert {:error, %{new_undocumented: ["7.99"]}} =
               DocCoverage.audit_against_baseline(registry, doc, baseline)
    end

    test "fails when the doc references a rule not in the registry (stale)" do
      registry = ["1.1"]
      doc = ["1.1", "9.99"]
      baseline = []

      assert {:error, %{stale: ["9.99"]}} =
               DocCoverage.audit_against_baseline(registry, doc, baseline)
    end
  end

  describe "audit_against_baseline/4 — missing + stale baselines" do
    test "passes when both lists are subsets of their baselines" do
      registry = ["1.1", "5.99", "6.99"]
      doc = ["1.1", "9.99", "9.aa"]
      missing_baseline = ["5.99", "6.99"]
      stale_baseline = ["9.99", "9.aa"]

      assert :ok =
               DocCoverage.audit_against_baseline(
                 registry,
                 doc,
                 missing_baseline,
                 stale_baseline
               )
    end

    test "passes when missing or stale shrunk (subset of baseline)" do
      registry = ["1.1", "5.99", "6.99"]
      doc = ["1.1", "5.99", "9.99"]
      # 5.99 was in missing-baseline but is now documented
      # 9.aa was in stale-baseline but was cleaned up
      missing_baseline = ["5.99", "6.99"]
      stale_baseline = ["9.99", "9.aa"]

      assert :ok =
               DocCoverage.audit_against_baseline(
                 registry,
                 doc,
                 missing_baseline,
                 stale_baseline
               )
    end

    test "fails when a NEW stale entry appears (not in stale baseline)" do
      registry = ["1.1"]
      doc = ["1.1", "9.99", "9.bb"]
      missing_baseline = []
      stale_baseline = ["9.99"]

      assert {:error, %{new_stale: ["9.bb"]}} =
               DocCoverage.audit_against_baseline(
                 registry,
                 doc,
                 missing_baseline,
                 stale_baseline
               )
    end

    test "fails when a NEW missing entry appears (not in missing baseline)" do
      registry = ["1.1", "5.99", "7.99"]
      doc = ["1.1"]
      missing_baseline = ["5.99"]
      stale_baseline = []

      assert {:error, %{new_undocumented: ["7.99"]}} =
               DocCoverage.audit_against_baseline(
                 registry,
                 doc,
                 missing_baseline,
                 stale_baseline
               )
    end
  end
end
