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

      assert_clean(CrossCuttingInDomain, code,
        file: "lib/my_app_web/controllers/account_controller.ex"
      )
    end

    test "skips operational layer (Mix tasks) via Phoenix classification" do
      # FP-7: Mix tasks ARE the cross-cutting boundary; Logger noise
      # there is appropriate, not domain pollution.
      code = ~S"""
      defmodule Mix.Tasks.MyApp.Migrate do
        use Mix.Task

        @impl Mix.Task
        def run(_args) do
          Logger.info("Starting migration")
          Logger.info("Pre-checks passed")
          Logger.info("Running migration step 1")
          Logger.info("Running migration step 2")
          Logger.info("Done")
          :ok
        end
      end
      """

      assert_clean(CrossCuttingInDomain, code, file: "lib/mix/tasks/my_app/migrate.ex")
    end

    test "skips test layer via Phoenix classification" do
      code = ~S"""
      defmodule MyApp.AccountsTest do
        use ExUnit.Case

        test "x" do
          Logger.info("setup")
          Logger.info("act")
          Logger.info("assert")
          Logger.info("done")
        end
      end
      """

      assert_clean(CrossCuttingInDomain, code, file: "test/my_app/accounts_test.exs")
    end
  end
end
