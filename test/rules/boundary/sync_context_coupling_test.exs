defmodule Archdo.Rules.Boundary.SyncContextCouplingTest do
  use ExUnit.Case, async: true

  alias Archdo.FunctionGraph
  alias Archdo.Rules.Boundary.SyncContextCoupling

  defp build_graph(file_code_pairs) do
    file_asts =
      Enum.map(file_code_pairs, fn {file, code} ->
        {:ok, ast} = Code.string_to_quoted(code, file: file, columns: true, token_metadata: true)
        {file, ast}
      end)

    FunctionGraph.build(file_asts)
  end

  defp contexts(names), do: Enum.map(names, &Module.concat(["MyApp", &1]))

  test "flags cross-context write call" do
    graph =
      build_graph([
        {"lib/my_app/orders.ex", """
          defmodule MyApp.Orders do
            def create(attrs) do
              MyApp.Billing.create_invoice(attrs)
            end
          end
        """},
        {"lib/my_app/billing.ex", """
          defmodule MyApp.Billing do
            def create_invoice(attrs), do: :ok
          end
        """}
      ])

    diags = SyncContextCoupling.analyze_project(graph, contexts(["Orders", "Billing"]))
    assert length(diags) == 1
    assert hd(diags).rule_id == "1.13"
    assert hd(diags).message =~ "create_invoice"
    assert hd(diags).message =~ "event-driven"
  end

  test "allows cross-context read call" do
    graph =
      build_graph([
        {"lib/my_app/orders.ex", """
          defmodule MyApp.Orders do
            def show(id) do
              MyApp.Accounts.get_user(id)
            end
          end
        """},
        {"lib/my_app/accounts.ex", """
          defmodule MyApp.Accounts do
            def get_user(id), do: nil
          end
        """}
      ])

    diags = SyncContextCoupling.analyze_project(graph, contexts(["Orders", "Accounts"]))
    assert diags == []
  end

  test "allows same-context write call" do
    graph =
      build_graph([
        {"lib/my_app/orders.ex", """
          defmodule MyApp.Orders do
            def create(attrs) do
              MyApp.Orders.Repo.insert(attrs)
            end
          end
        """},
        {"lib/my_app/orders/repo.ex", """
          defmodule MyApp.Orders.Repo do
            def insert(attrs), do: :ok
          end
        """}
      ])

    diags = SyncContextCoupling.analyze_project(graph, contexts(["Orders"]))
    assert diags == []
  end

  test "allows web controller calling context write" do
    graph =
      build_graph([
        {"lib/my_app_web/controllers/user_controller.ex", """
          defmodule MyAppWeb.UserController do
            def create(conn, params) do
              MyApp.Accounts.create_user(params)
            end
          end
        """},
        {"lib/my_app/accounts.ex", """
          defmodule MyApp.Accounts do
            def create_user(attrs), do: :ok
          end
        """}
      ])

    diags = SyncContextCoupling.analyze_project(graph, contexts(["Accounts"]))
    assert diags == []
  end

  test "returns empty when no contexts configured" do
    graph =
      build_graph([
        {"lib/my_app/orders.ex", """
          defmodule MyApp.Orders do
            def create(attrs), do: MyApp.Billing.create_invoice(attrs)
          end
        """}
      ])

    diags = SyncContextCoupling.analyze_project(graph, [])
    assert diags == []
  end
end
