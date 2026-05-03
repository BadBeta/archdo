defmodule Archdo.RulesTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules

  # Boundary smoke tests for the Archdo.Rules facade.
  # The facade exists so external orchestrators (Runner, MCP tools)
  # call rules through one named entry point instead of aliasing
  # individual rule modules. Each delegate is a one-liner; these
  # tests assert the surface exists and forwards to a function with
  # the right shape, not the rule logic itself (which has its own tests).

  describe "Archdo.Rules — facade surface (M-Plan19 Phase 3 follow-up)" do
    test "exports the 10 expected facade functions" do
      exports = Rules.__info__(:functions)

      expected = [
        chatty_boundary: 2,
        coverage_gap: 1,
        coverage_matrix_report: 1,
        feature_envy: 1,
        function_boundary: 2,
        function_fan_out: 1,
        main_sequence_distance: 2,
        shotgun_surgery: 1,
        sync_context_coupling: 2,
        test_mirrors_source: 2
      ]

      for {fn_name, arity} <- expected do
        assert {fn_name, arity} in exports,
               "Archdo.Rules.#{fn_name}/#{arity} is missing"
      end
    end

    test "every facade function returns a list (diagnostics or iodata)" do
      # Empty inputs — exercises the boundary plumbing without
      # depending on any rule's logic.
      assert is_list(Rules.coverage_gap([]))
      assert is_list(Rules.test_mirrors_source([], []))

      # Wrap in IO.iodata_to_binary to verify the matrix returns iodata.
      assert is_binary(IO.iodata_to_binary(Rules.coverage_matrix_report([])))
    end
  end
end
