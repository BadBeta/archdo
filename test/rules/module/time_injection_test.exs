defmodule Archdo.Rules.Module.TimeInjectionTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.TimeInjection

  describe "analyze/3" do
    test "flags direct DateTime.utc_now call in domain code" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def create_user(attrs) do
          now = DateTime.utc_now()
          Map.put(attrs, :created_at, now)
        end
      end
      """

      diags = assert_flagged(TimeInjection, code)
      assert hd(diags).rule_id == "1.9"
      assert hd(diags).message =~ "DateTime.utc_now"
    end

    test "allows time calls in test files" do
      code = ~S"""
      defmodule MyApp.AccountsTest do
        def setup_user do
          now = DateTime.utc_now()
          %{created_at: now}
        end
      end
      """

      assert_clean(TimeInjection, code, file: "test/accounts_test.exs")
    end

    test "allows time calls in infrastructure files" do
      code = ~S"""
      defmodule MyApp.Clock do
        def now, do: DateTime.utc_now()
      end
      """

      assert_clean(TimeInjection, code, file: "lib/my_app/clock.ex")
    end
  end
end
