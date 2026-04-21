defmodule Archdo.Rules.Testing.UntestedModuleTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Testing.UntestedModule

  describe "analyze/3" do
    test "flags source module with no test file" do
      code = ~S"""
      defmodule MyApp.Accounts.User do
        @moduledoc "User schema"
        def changeset(user, attrs), do: {user, attrs}
      end
      """

      # Use a path where no test file will exist
      diags = assert_flagged(UntestedModule, code, file: "lib/nonexistent_project/accounts/user.ex")
      assert hd(diags).rule_id == "7.25"
      assert hd(diags).message =~ "no test file"
    end

    test "skips internal modules with @moduledoc false" do
      code = ~S"""
      defmodule MyApp.Internal do
        @moduledoc false
        def helper, do: :ok
      end
      """

      assert_clean(UntestedModule, code, file: "lib/nonexistent_project/internal.ex")
    end

    test "skips migration files" do
      code = ~S"""
      defmodule MyApp.Repo.Migrations.CreateUsers do
        use Ecto.Migration

        def change do
          create table(:users) do
            add :name, :string
          end
        end
      end
      """

      assert_clean(UntestedModule, code, file: "lib/my_app/repo/migrations/20240101_create_users.ex")
    end

    test "skips config files like router.ex and endpoint.ex" do
      code = ~S"""
      defmodule MyAppWeb.Router do
        use Phoenix.Router
        get "/", PageController, :index
      end
      """

      assert_clean(UntestedModule, code, file: "lib/my_app_web/router.ex")
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.AccountsTest do
        use ExUnit.Case
        test "it works" do
          assert true
        end
      end
      """

      assert_clean(UntestedModule, code, file: "test/my_app/accounts_test.exs")
    end

    test "source_to_test_path/1 converts paths correctly" do
      assert UntestedModule.source_to_test_path("lib/my_app/accounts/user.ex") ==
               "test/my_app/accounts/user_test.exs"

      assert UntestedModule.source_to_test_path("lib/my_app_web/controllers/page_controller.ex") ==
               "test/my_app_web/controllers/page_controller_test.exs"
    end
  end
end
