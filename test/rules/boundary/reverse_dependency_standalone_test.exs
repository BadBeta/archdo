defmodule Archdo.Rules.Boundary.ReverseDependencyStandaloneTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Boundary.ReverseDependency

  defp analyze(code, file) do
    {:ok, ast} = Code.string_to_quoted(code, columns: true, token_metadata: true,
      literal_encoder: &{:ok, {:__block__, &2, [&1]}})
    ReverseDependency.analyze(file, ast, [])
  end

  test "flags alias to Web module from domain" do
    diags = analyze("""
    defmodule MyApp.Accounts.User do
      alias MyAppWeb.Router.Helpers
      def url, do: Helpers.user_path(nil, :show, 1)
    end
    """, "lib/my_app/accounts/user.ex")

    assert [%{rule_id: "1.26"}] = diags
  end

  test "flags remote call to Web module from domain" do
    diags = analyze("""
    defmodule MyApp.Accounts.Notifier do
      def notify(user) do
        MyAppWeb.Endpoint.broadcast("users", "update", user)
      end
    end
    """, "lib/my_app/accounts/notifier.ex")

    assert [%{rule_id: "1.26"}] = diags
  end

  test "clean: web module referencing web is fine" do
    assert [] == analyze("""
    defmodule MyAppWeb.UserController do
      alias MyAppWeb.Router.Helpers
      def show(conn, _), do: Helpers.user_path(conn, :show)
    end
    """, "lib/my_app_web/controllers/user_controller.ex")
  end

  test "clean: domain module without web references" do
    assert [] == analyze("""
    defmodule MyApp.Accounts do
      alias MyApp.Accounts.User
      def get(id), do: User.get(id)
    end
    """, "lib/my_app/accounts.ex")
  end

  test "skips test files" do
    assert [] == analyze("""
    defmodule MyApp.AccountsTest do
      alias MyAppWeb.ConnCase
      def test_something, do: :ok
    end
    """, "test/my_app/accounts_test.exs")
  end
end
