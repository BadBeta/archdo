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

    test "does not flag substring 'Web' in non-web modules (BUG-10)" do
      # `Livebook.Teams.WebSocket` is a sub-module that happens to contain the
      # substring "WebSocket" — but it lives in `Livebook.Teams`, not in any
      # `*Web` namespace. The previous regex matched "Web" as substring,
      # producing false positives on Webhook, WebSocket, WebrtcClient, etc.
      code = ~S"""
      defmodule MyApp.Teams.Connection do
        alias MyApp.Teams.WebSocket

        def open(opts) do
          MyApp.Teams.WebSocket.connect(opts)
        end
      end
      """

      assert_clean(ReverseDependency, code, file: "lib/my_app/teams/connection.ex")
    end

    test "does not flag application supervisor wiring up web Endpoint (BUG-10)" do
      # `lib/my_app/application.ex` is the supervisor root — it legitimately
      # references every child including the web Endpoint. Flagging this is
      # a false-positive class on every Phoenix project.
      code = ~S"""
      defmodule MyApp.Application do
        use Application

        def start(_type, _args) do
          children = [
            MyApp.Repo,
            MyAppWeb.Endpoint
          ]

          Supervisor.start_link(children, strategy: :one_for_one)
        end
      end
      """

      assert_clean(ReverseDependency, code, file: "lib/my_app/application.ex")
    end

    test "still flags real web reference from a domain module" do
      code = ~S"""
      defmodule MyApp.Accounts do
        alias MyAppWeb.UserController

        def list_users do
          UserController.format(MyApp.Repo.all(MyApp.User))
        end
      end
      """

      diags = assert_flagged(ReverseDependency, code, file: "lib/my_app/accounts.ex")
      assert hd(diags).rule_id == "1.26"
    end

    test "still flags Web as a standalone namespace segment" do
      # `MyApp.Web.Foo` — middle segment IS "Web". Web layer.
      code = ~S"""
      defmodule MyApp.Accounts do
        alias MyApp.Web.Helper
      end
      """

      diags = assert_flagged(ReverseDependency, code, file: "lib/my_app/accounts.ex")
      assert hd(diags).rule_id == "1.26"
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
