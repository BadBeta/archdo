defmodule Archdo.Rules.Boundary.GraphRulesTest do
  use ExUnit.Case, async: true

  alias Archdo.{Config, Graph}
  alias Archdo.Rules.Boundary.{
    DependencyDirection,
    FrameworkInDomain,
    ContextEncapsulation,
    CircularDependencies,
    RepoInInterface
  }

  defp build_graph(file_code_pairs) do
    file_asts =
      Enum.map(file_code_pairs, fn {file, code} ->
        {:ok, ast} = Code.string_to_quoted(code, file: file, columns: true, token_metadata: true)
        {file, ast}
      end)

    Graph.build(file_asts)
  end

  defp test_config(overrides \\ []) do
    %Config{
      layers: %{
        interface: ~r/^MyAppWeb\./,
        domain: ~r/^MyApp\.(?!Repo)/,
        infrastructure: ~r/^MyApp\.Repo/
      },
      allowed_deps: %{
        interface: [:domain, :infrastructure],
        domain: [:infrastructure],
        infrastructure: []
      },
      contexts: Keyword.get(overrides, :contexts, [MyApp.Accounts, MyApp.Billing]),
      adapters: ~r/\.Adapters?\./,
      framework_modules: [
        ~r/^Phoenix\.Controller/,
        ~r/^Phoenix\.LiveView/,
        ~r/^Phoenix\.Router/,
        ~r/^Plug\./
      ],
      app_module: "MyApp",
      web_module: "MyAppWeb"
    }
  end

  describe "1.1 DependencyDirection" do
    test "flags domain depending on interface" do
      graph = build_graph([
        {"lib/my_app/accounts.ex", ~S"""
        defmodule MyApp.Accounts do
          alias MyAppWeb.Router.Helpers
          def url, do: Helpers.user_path(nil, :index)
        end
        """}
      ])

      diags = DependencyDirection.analyze_graph(graph, test_config())
      assert length(diags) > 0
      assert hd(diags).severity == :error
      assert hd(diags).message =~ "domain"
      assert hd(diags).message =~ "interface"
    end

    test "allows interface depending on domain" do
      graph = build_graph([
        {"lib/my_app_web/user_controller.ex", ~S"""
        defmodule MyAppWeb.UserController do
          alias MyApp.Accounts
          def index(conn, _), do: Accounts.list_users()
        end
        """}
      ])

      diags = DependencyDirection.analyze_graph(graph, test_config())
      assert diags == []
    end

    test "tolerates Ecto in domain" do
      graph = build_graph([
        {"lib/my_app/accounts.ex", ~S"""
        defmodule MyApp.Accounts do
          import Ecto.Query
          def list_users, do: Ecto.Query.from(u in "users")
        end
        """}
      ])

      diags = DependencyDirection.analyze_graph(graph, test_config())
      assert diags == []
    end
  end

  describe "1.1b FrameworkInDomain" do
    test "flags domain using Phoenix.LiveView" do
      graph = build_graph([
        {"lib/my_app/dashboard.ex", ~S"""
        defmodule MyApp.Dashboard do
          import Phoenix.LiveView
          def render(assigns), do: nil
        end
        """}
      ])

      diags = FrameworkInDomain.analyze_graph(graph, test_config())
      assert length(diags) > 0
      assert hd(diags).severity == :warning
      assert hd(diags).message =~ "framework"
    end

    test "allows interface using Phoenix.LiveView" do
      graph = build_graph([
        {"lib/my_app_web/live/dashboard_live.ex", ~S"""
        defmodule MyAppWeb.DashboardLive do
          use Phoenix.LiveView
          def render(assigns), do: nil
        end
        """}
      ])

      diags = FrameworkInDomain.analyze_graph(graph, test_config())
      assert diags == []
    end
  end

  describe "1.2 ContextEncapsulation" do
    test "flags external module reaching into context internals via call" do
      graph = build_graph([
        {"lib/my_app_web/user_controller.ex", ~S"""
        defmodule MyAppWeb.UserController do
          def index(conn, _) do
            MyApp.Accounts.UserQuery.active()
          end
        end
        """}
      ])

      diags = ContextEncapsulation.analyze_graph(graph, test_config())
      assert length(diags) > 0
      assert hd(diags).message =~ "internal to"
      assert hd(diags).message =~ "Accounts"
    end

    test "allows calling context root module" do
      graph = build_graph([
        {"lib/my_app_web/user_controller.ex", ~S"""
        defmodule MyAppWeb.UserController do
          def index(conn, _) do
            MyApp.Accounts.list_users()
          end
        end
        """}
      ])

      diags = ContextEncapsulation.analyze_graph(graph, test_config())
      assert diags == []
    end

    test "allows internal calls within same context" do
      graph = build_graph([
        {"lib/my_app/accounts.ex", ~S"""
        defmodule MyApp.Accounts do
          def list_users do
            MyApp.Accounts.UserQuery.active()
          end
        end
        """}
      ])

      diags = ContextEncapsulation.analyze_graph(graph, test_config())
      assert diags == []
    end
  end

  describe "1.3 CircularDependencies" do
    test "detects circular dependency between contexts" do
      graph = build_graph([
        {"lib/my_app/accounts.ex", ~S"""
        defmodule MyApp.Accounts do
          def get_billing(user), do: MyApp.Billing.for_user(user)
        end
        """},
        {"lib/my_app/billing.ex", ~S"""
        defmodule MyApp.Billing do
          def get_account(bill), do: MyApp.Accounts.get(bill.user_id)
        end
        """}
      ])

      diags = CircularDependencies.analyze_graph(graph, test_config())
      assert length(diags) > 0
      assert hd(diags).severity == :error
      assert hd(diags).message =~ "Circular"
    end

    test "allows one-way dependency" do
      graph = build_graph([
        {"lib/my_app/billing.ex", ~S"""
        defmodule MyApp.Billing do
          def for_user(user), do: MyApp.Accounts.get(user.id)
        end
        """},
        {"lib/my_app/accounts.ex", ~S"""
        defmodule MyApp.Accounts do
          def get(id), do: {:ok, id}
        end
        """}
      ])

      diags = CircularDependencies.analyze_graph(graph, test_config())
      assert diags == []
    end
  end

  describe "1.4 RepoInInterface" do
    test "flags Repo call from controller" do
      graph = build_graph([
        {"lib/my_app_web/user_controller.ex", ~S"""
        defmodule MyAppWeb.UserController do
          def index(conn, _) do
            users = MyApp.Repo.all(User)
          end
        end
        """}
      ])

      diags = RepoInInterface.analyze_graph(graph, test_config())
      assert length(diags) > 0
      assert hd(diags).severity == :warning
      assert hd(diags).message =~ "Repo"
    end

    test "allows domain calling Repo" do
      graph = build_graph([
        {"lib/my_app/accounts.ex", ~S"""
        defmodule MyApp.Accounts do
          def list_users, do: MyApp.Repo.all(User)
        end
        """}
      ])

      diags = RepoInInterface.analyze_graph(graph, test_config())
      assert diags == []
    end
  end
end
