defmodule Archdo.Rules.Boundary.BoundaryBypassTest do
  use ExUnit.Case, async: true

  defp analyze(module, code, file \\ "lib/my_app/accounts/user.ex") do
    {:ok, ast} = Code.string_to_quoted(code, columns: true, token_metadata: true,
      literal_encoder: &{:ok, {:__block__, &2, [&1]}})
    module.analyze(file, ast, [])
  end

  # --- 1.28: Query in Interface ---

  describe "QueryInInterface (1.28)" do
    test "flags import Ecto.Query in controller" do
      diags = analyze(Archdo.Rules.Boundary.QueryInInterface, """
      defmodule MyAppWeb.UserController do
        import Ecto.Query
        def index(conn, _params), do: conn
      end
      """, "lib/my_app_web/controllers/user_controller.ex")

      assert [%{rule_id: "1.28"}] = diags
    end

    test "flags from() in LiveView" do
      diags = analyze(Archdo.Rules.Boundary.QueryInInterface, """
      defmodule MyAppWeb.UserLive do
        def mount(_params, _session, socket) do
          users = from(u in User, where: u.active == true)
          {:ok, assign(socket, :users, users)}
        end
      end
      """, "lib/my_app_web/live/user_live.ex")

      assert [%{rule_id: "1.28"}] = diags
    end

    test "clean: query in context module is fine" do
      diags = analyze(Archdo.Rules.Boundary.QueryInInterface, """
      defmodule MyApp.Accounts do
        import Ecto.Query
        def list_users, do: from(u in User)
      end
      """, "lib/my_app/accounts.ex")

      assert diags == []
    end
  end

  # --- 1.29: Cross-Context Schema ---

  describe "CrossContextSchema (1.29)" do
    test "flags constructing another context's schema" do
      diags = analyze(Archdo.Rules.Boundary.CrossContextSchema, """
      defmodule MyApp.Billing.Invoice do
        def create(user) do
          %MyApp.Accounts.User{name: user.name}
        end
      end
      """, "lib/my_app/billing/invoice.ex")

      assert [%{rule_id: "1.29"}] = diags
    end

    test "clean: own context schema is fine" do
      diags = analyze(Archdo.Rules.Boundary.CrossContextSchema, """
      defmodule MyApp.Accounts.Registration do
        def build do
          %MyApp.Accounts.User{name: "test"}
        end
      end
      """, "lib/my_app/accounts/registration.ex")

      assert diags == []
    end
  end

  # --- 1.30: Direct Process Call ---

  describe "DirectProcessCall (1.30)" do
    test "flags GenServer.call to another context's server" do
      diags = analyze(Archdo.Rules.Boundary.DirectProcessCall, """
      defmodule MyApp.Billing.Processor do
        def check_credit(user_id) do
          GenServer.call(MyApp.Accounts.CreditServer, {:check, user_id})
        end
      end
      """, "lib/my_app/billing/processor.ex")

      assert [%{rule_id: "1.30"}] = diags
    end

    test "clean: calling own context's server is fine" do
      diags = analyze(Archdo.Rules.Boundary.DirectProcessCall, """
      defmodule MyApp.Billing.Invoice do
        def total do
          GenServer.call(MyApp.Billing.Calculator, :total)
        end
      end
      """, "lib/my_app/billing/invoice.ex")

      assert diags == []
    end
  end

  # --- 1.32: Cross-Context Config ---

  describe "CrossContextConfig (1.32)" do
    test "flags reading another context's config module" do
      diags = analyze(Archdo.Rules.Boundary.CrossContextConfig, """
      defmodule MyApp.Billing.Pricer do
        def rate do
          Application.get_env(:my_app, MyApp.Accounts.Config)
        end
      end
      """, "lib/my_app/billing/pricer.ex")

      assert [%{rule_id: "1.32"}] = diags
    end

    test "clean: reading own context config is fine" do
      diags = analyze(Archdo.Rules.Boundary.CrossContextConfig, """
      defmodule MyApp.Billing.Pricer do
        def rate do
          Application.get_env(:my_app, MyApp.Billing.Config)
        end
      end
      """, "lib/my_app/billing/pricer.ex")

      assert diags == []
    end
  end
end
