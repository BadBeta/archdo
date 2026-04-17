defmodule Archdo.Rules.Testing.MocksNeedBehavioursTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Testing.MocksNeedBehaviours

  describe "analyze/3" do
    test "flags Mox.defmock without :for option" do
      code = ~S"""
      defmodule MyApp.TestSetup do
        Mox.defmock(MyMock, [])
      end
      """

      diags = assert_flagged(MocksNeedBehaviours, code, file: "test/support/mocks.exs")
      assert hd(diags).rule_id == "7.3"
    end

    test "allows Mox.defmock with :for option" do
      code = ~S"""
      defmodule MyApp.TestSetup do
        Mox.defmock(MyMock, for: MyApp.HTTPClient)
      end
      """

      assert_clean(MocksNeedBehaviours, code, file: "test/support/mocks.exs")
    end
  end
end
