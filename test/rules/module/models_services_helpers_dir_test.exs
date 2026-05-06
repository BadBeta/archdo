defmodule Archdo.Rules.Module.ModelsServicesHelpersDirTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.ModelsServicesHelpersDir

  describe "analyze/3" do
    test "flags file under lib/.../models/" do
      code = ~S"""
      defmodule MyApp.Models.User do
        defstruct [:name]
      end
      """

      diags =
        assert_flagged(ModelsServicesHelpersDir, code, file: "lib/my_app/models/user.ex")

      assert hd(diags).rule_id == "1.34"
    end

    test "flags file under lib/.../services/" do
      code = ~S"""
      defmodule MyApp.Services.PaymentProcessor do
        def call, do: :ok
      end
      """

      assert_flagged(ModelsServicesHelpersDir, code,
        file: "lib/my_app/services/payment_processor.ex"
      )
    end

    test "flags file under lib/.../helpers/" do
      code = ~S"""
      defmodule MyApp.Helpers.Format do
        def call, do: :ok
      end
      """

      assert_flagged(ModelsServicesHelpersDir, code, file: "lib/my_app/helpers/format.ex")
    end

    test "ignores domain-named directories" do
      code = ~S"""
      defmodule MyApp.Accounts.User do
        defstruct [:name]
      end
      """

      assert_clean(ModelsServicesHelpersDir, code, file: "lib/my_app/accounts/user.ex")
    end

    test "ignores test files even if path contains 'helpers'" do
      code = ~S"""
      defmodule MyApp.TestHelpers do
        def setup_data, do: :ok
      end
      """

      assert_clean(ModelsServicesHelpersDir, code, file: "test/support/test_helpers.ex")
    end

    test "ignores web layer helpers (HTML/view helpers are conventional)" do
      code = ~S"""
      defmodule MyAppWeb.Helpers.NavHelper do
        def call, do: :ok
      end
      """

      assert_clean(ModelsServicesHelpersDir, code, file: "lib/my_app_web/helpers/nav_helper.ex")
    end
  end
end
