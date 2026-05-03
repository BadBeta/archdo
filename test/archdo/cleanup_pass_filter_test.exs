defmodule Archdo.CleanupPassFilterTest do
  use ExUnit.Case, async: true

  alias Archdo.Runner

  @cg1 Archdo.Rules.Module.UnsafeDeserialization
  @cg3 Archdo.Rules.Module.StacktraceInResponse
  @cg6 Archdo.Rules.Boundary.AtomAtBoundary
  @cg11 Archdo.Rules.OTP.AsyncDropsLoggerMetadata
  @existing Archdo.Rules.Module.RegexInLoop

  describe "filter_rules_for_cleanup_pass/2" do
    test "returns only rules tagged with the given pass" do
      rules = [@cg1, @cg3, @cg6, @cg11, @existing]

      assert Runner.filter_rules_for_cleanup_pass(rules, 6) == [@cg1]
      assert Runner.filter_rules_for_cleanup_pass(rules, 5) == [@cg3]
      assert Runner.filter_rules_for_cleanup_pass(rules, 3) == [@cg6]
      assert Runner.filter_rules_for_cleanup_pass(rules, 13) == [@cg11]
    end

    test "returns empty list for pass with no matching rules" do
      assert Runner.filter_rules_for_cleanup_pass([@cg1], 13) == []
    end

    test "returns empty list for invalid pass number" do
      assert Runner.filter_rules_for_cleanup_pass([@cg1], 99) == []
    end

    test "drops rules without a cleanup_pass tag" do
      # @existing (RegexInLoop, id 6.49) IS in the cleanup pass map (pass 14),
      # so this test uses a rule that isn't mapped.
      unmapped = Archdo.Rules.CE.BlackboxQuadrant
      assert Runner.filter_rules_for_cleanup_pass([unmapped], 14) == []
    end
  end

  describe "Runner.analyze/2 with :cleanup_pass option" do
    @tag :tmp_dir
    test "filters rules to a specific pass", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "controller.ex")

      File.write!(file, """
      defmodule MyAppWeb.OrderController do
        use Phoenix.Controller

        def show(conn, %{"sort" => sort}) do
          # RULE-EXCEPTION: elixir-string-to-atom-untrusted — test fixture
          render(conn, :show, sort: String.to_atom(sort))
        end
      end
      """)

      # Without filter: should produce findings from multiple rules
      diags_unfiltered = Runner.analyze([file])
      assert match?([_ | _], diags_unfiltered)

      # With filter to pass 3 (atom safety): only pass-3 rules fire.
      # Both 1.20 (atom_at_boundary) and 5.24 (dynamic_atom_name) match.
      diags_pass3 = Runner.analyze([file], cleanup_pass: 3)
      assert Enum.all?(diags_pass3, &(&1.rule_id in ["1.20", "5.24"]))
      assert match?([_ | _], diags_pass3)

      # With filter to pass 6 (deserialization/eval): no findings on this file
      assert Runner.analyze([file], cleanup_pass: 6) == []
    end
  end
end
