defmodule Archdo.Rules.Module.SingleImplProtocolTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.SingleImplProtocol

  describe "analyze/3" do
    test "allows protocol definition (per-file rule, no project context)" do
      code = ~S"""
      defprotocol MyApp.Renderable do
        def render(item)
      end
      """

      # SingleImplProtocol is a per-file rule — it can only check
      # individual files, not count implementations across the project
      assert_clean(SingleImplProtocol, code)
    end
  end
end
