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
  end
end
