defmodule Archdo.Rules.Module.NaturalSeamsTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.NaturalSeams

  describe "analyze/3" do
    test "flags module with multiple prefix clusters" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def user_create(attrs), do: attrs
        def user_update(user, attrs), do: user
        def user_delete(user), do: :ok
        def user_list, do: []

        def team_create(attrs), do: attrs
        def team_update(team, attrs), do: team
        def team_delete(team), do: :ok
        def team_list, do: []
      end
      """

      diags = assert_flagged(NaturalSeams, code)
      assert hd(diags).rule_id == "4.14"
      assert hd(diags).message =~ "prefix clusters"
    end

    test "allows module without prefix patterns" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def create(attrs), do: attrs
        def update(record, attrs), do: record
        def delete(record), do: :ok
        def list, do: []
      end
      """

      assert_clean(NaturalSeams, code)
    end

    test "does NOT flag a multi-clause function as if every clause were a separate prefix-cluster member" do
      # This was a real false positive: a single multi-clause function
      # with N heads (e.g. `builder_for(:error)` / `(:warning)` / etc.)
      # was counted as N separate `builder_*` functions. After the fix,
      # the prefix group counts UNIQUE function names, not clause count.
      code = ~S"""
      defmodule MyApp.Diagnostic do
        def builder_for(:error), do: :error_builder
        def builder_for(:warning), do: :warning_builder
        def builder_for(:info), do: :info_builder
        def builder_for(:nitpick), do: :nitpick_builder

        def severity_order(:error), do: 0
        def severity_order(:warning), do: 1
        def severity_order(:info), do: 2
        def severity_order(:nitpick), do: 3
      end
      """

      assert_clean(NaturalSeams, code)
    end

    test "still flags genuine clusters that share a prefix across DIFFERENT functions" do
      # Four DIFFERENT functions all named `user_*` is a real cluster,
      # vs. one function with four clauses (which is not).
      code = ~S"""
      defmodule MyApp.Accounts do
        def user_create(attrs), do: attrs
        def user_update(u, attrs), do: u
        def user_delete(u), do: :ok
        def user_list, do: []

        def team_create(attrs), do: attrs
        def team_update(t, attrs), do: t
        def team_delete(t), do: :ok
        def team_list, do: []
      end
      """

      assert [_diag] = assert_flagged(NaturalSeams, code)
    end
  end
end
