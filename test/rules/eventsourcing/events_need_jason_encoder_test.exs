defmodule Archdo.Rules.EventSourcing.EventsNeedJasonEncoderTest do
  use Archdo.RuleCase

  alias Archdo.Rules.EventSourcing.EventsNeedJasonEncoder

  describe "analyze/3" do
    test "flags event struct without Jason.Encoder derivation" do
      code = ~S"""
      defmodule MyApp.Events.AccountOpened do
        defstruct [:account_id, :name]
      end
      """

      diags = assert_flagged(EventsNeedJasonEncoder, code)
      assert hd(diags).rule_id == "8.5"
      assert hd(diags).message =~ "Jason.Encoder"
    end

    test "allows event with @derive Jason.Encoder" do
      code = ~S"""
      defmodule MyApp.Events.AccountOpened do
        @derive Jason.Encoder
        defstruct [:account_id, :name]
      end
      """

      assert_clean(EventsNeedJasonEncoder, code)
    end

    test "ignores non-event modules" do
      code = ~S"""
      defmodule MyApp.Accounts.User do
        defstruct [:id, :name]
      end
      """

      assert_clean(EventsNeedJasonEncoder, code)
    end
  end
end
