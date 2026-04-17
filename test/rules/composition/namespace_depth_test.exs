defmodule Archdo.Rules.Composition.NamespaceDepthTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Composition.NamespaceDepth

  describe "analyze/3" do
    test "flags module with >4 nesting levels" do
      code = ~S"""
      defmodule MyApp.Domain.Accounts.Users.Profiles.Settings do
        def get, do: %{}
      end
      """

      diags = assert_flagged(NamespaceDepth, code)
      assert hd(diags).rule_id == "10.2"
      assert hd(diags).message =~ "nesting levels"
    end

    test "allows module with 4 or fewer levels" do
      code = ~S"""
      defmodule MyApp.Accounts.User do
        def get, do: %{}
      end
      """

      assert_clean(NamespaceDepth, code)
    end
  end
end
