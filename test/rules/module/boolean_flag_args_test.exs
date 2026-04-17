defmodule Archdo.Rules.Module.BooleanFlagArgsTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.BooleanFlagArgs

  describe "analyze/3" do
    test "flags function with is_ prefixed boolean arg" do
      code = ~S"""
      defmodule MyApp.Formatter do
        def format(data, is_admin) do
          if is_admin, do: admin_format(data), else: user_format(data)
        end
      end
      """

      diags = assert_flagged(BooleanFlagArgs, code)
      assert hd(diags).rule_id == "6.6"
    end

    test "allows function without flag-pattern arguments" do
      code = ~S"""
      defmodule MyApp.Formatter do
        def format(data, style) do
          apply_style(data, style)
        end
      end
      """

      assert_clean(BooleanFlagArgs, code)
    end

    test "allows predicate functions (ending with ?)" do
      code = ~S"""
      defmodule MyApp.User do
        def active?(user) do
          user.active
        end
      end
      """

      assert_clean(BooleanFlagArgs, code)
    end
  end
end
