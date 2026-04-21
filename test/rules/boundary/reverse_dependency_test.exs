defmodule Archdo.Rules.Boundary.ReverseDependencyTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Boundary.ReverseDependency

  describe "analyze/3" do
    test "flags alias of web module in domain file" do
      code = ~S"""
      defmodule MyApp.Accounts do
        alias MyAppWeb.UserController

        def list_users do
          UserController.index()
        end
      end
      """

      diags = assert_flagged(ReverseDependency, code, file: "lib/my_app/accounts.ex")
      diag = hd(diags)
      assert diag.severity == :warning
      assert diag.rule_id == "1.26"
      assert diag.context.kind == :alias
      assert diag.context.web_module =~ "Web"
    end

    test "flags import of web router helpers in domain file" do
      code = ~S"""
      defmodule MyApp.Notifications do
        import MyAppWeb.Router.Helpers

        def build_url(user) do
          user_path(%{}, :show, user.id)
        end
      end
      """

      diags = assert_flagged(ReverseDependency, code, file: "lib/my_app/notifications.ex")
      diag = hd(diags)
      assert diag.context.kind == :import
    end

    test "flags remote calls to web modules in domain file" do
      code = ~S"""
      defmodule MyApp.Mailer do
        def send_welcome(user) do
          MyAppWeb.Endpoint.url() <> "/welcome"
        end
      end
      """

      diags = assert_flagged(ReverseDependency, code, file: "lib/my_app/mailer.ex")
      diag = hd(diags)
      assert diag.context.kind == :remote_call
    end

    test "allows web modules referencing other web modules" do
      code = ~S"""
      defmodule MyAppWeb.UserController do
        alias MyAppWeb.UserView

        def index(conn, _params) do
          render(conn, UserView, "index.html")
        end
      end
      """

      assert_clean(ReverseDependency, code, file: "lib/my_app_web/controllers/user_controller.ex")
    end

    test "allows domain modules referencing domain modules" do
      code = ~S"""
      defmodule MyApp.Accounts do
        alias MyApp.Accounts.User

        def get_user(id) do
          User.get(id)
        end
      end
      """

      assert_clean(ReverseDependency, code, file: "lib/my_app/accounts.ex")
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.AccountsTest do
        alias MyAppWeb.UserController

        test "something" do
          UserController.index()
        end
      end
      """

      assert_clean(ReverseDependency, code, file: "test/my_app/accounts_test.exs")
    end
  end
end
