defmodule Archdo.Rules.Module.CrossCuttingInDomainTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.CrossCuttingInDomain

  describe "analyze/3" do
    test "flags domain module with excessive Logger calls" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def create(attrs) do
          Logger.info("Creating account")
          Logger.info("Validating attrs")
          Logger.debug("Attrs: #{inspect(attrs)}")
          Logger.info("Account created")
          {:ok, attrs}
        end
      end
      """

      diags = assert_flagged(CrossCuttingInDomain, code, file: "lib/my_app/accounts.ex")
      assert hd(diags).rule_id == "1.6"
      assert hd(diags).message =~ "Logger"
    end

    test "allows few Logger calls in domain" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def create(attrs) do
          Logger.info("Account created")
          {:ok, attrs}
        end
      end
      """

      assert_clean(CrossCuttingInDomain, code, file: "lib/my_app/accounts.ex")
    end

    test "skips web files" do
      code = ~S"""
      defmodule MyAppWeb.AccountController do
        def create(conn, params) do
          Logger.info("Request received")
          Logger.info("Processing")
          Logger.info("Validating")
          Logger.info("Done")
          conn
        end
      end
      """

      assert_clean(CrossCuttingInDomain, code, file: "lib/my_app_web/controllers/account_controller.ex")
    end
  end
end
