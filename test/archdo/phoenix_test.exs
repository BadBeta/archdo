defmodule Archdo.PhoenixTest do
  use ExUnit.Case, async: true

  alias Archdo.Phoenix

  defp parse(code) do
    {:ok, ast} =
      Code.string_to_quoted(code,
        columns: true,
        token_metadata: true,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    ast
  end

  describe "classify_file/2 — layer detection" do
    test "returns :application_root for `use Application`" do
      ast =
        parse("""
        defmodule MyApp.Application do
          use Application
          def start(_, _), do: Supervisor.start_link([], strategy: :one_for_one)
        end
        """)

      assert Phoenix.classify_file("lib/my_app/application.ex", ast).layer == :application_root
    end

    test "returns :operational for `use Mix.Task`" do
      ast =
        parse("""
        defmodule Mix.Tasks.MyApp.Backfill do
          use Mix.Task
          def run(_), do: :ok
        end
        """)

      assert Phoenix.classify_file("lib/mix/tasks/my_app.backfill.ex", ast).layer == :operational
    end

    test "returns :operational for files under lib/<app>/data_migration/" do
      ast = parse("defmodule MyApp.DataMigration.Foo do\n  def run, do: :ok\nend")
      assert Phoenix.classify_file("lib/my_app/data_migration/foo.ex", ast).layer == :operational
    end

    test "returns :operational for release.ex" do
      ast = parse("defmodule MyApp.Release do\n  def migrate, do: :ok\nend")
      assert Phoenix.classify_file("lib/my_app/release.ex", ast).layer == :operational
    end

    test "returns :operational for priv/repo/seeds.exs" do
      ast = parse(":ok")
      assert Phoenix.classify_file("priv/repo/seeds.exs", ast).layer == :operational
    end

    test "returns :live_view for `use Phoenix.LiveView`" do
      ast =
        parse("""
        defmodule MyAppWeb.PageLive do
          use Phoenix.LiveView
          def mount(_, _, socket), do: {:ok, socket}
        end
        """)

      assert Phoenix.classify_file("lib/my_app_web/live/page_live.ex", ast).layer == :live_view
    end

    test "returns :live_view for `use MyAppWeb, :live_view`" do
      ast =
        parse("""
        defmodule MyAppWeb.PageLive do
          use MyAppWeb, :live_view
        end
        """)

      assert Phoenix.classify_file("lib/my_app_web/live/page_live.ex", ast).layer == :live_view
    end

    test "returns :component for `use Phoenix.Component`" do
      ast =
        parse("""
        defmodule MyAppWeb.CoreComponents do
          use Phoenix.Component
          def button(assigns), do: ~H"<button>x</button>"
        end
        """)

      assert Phoenix.classify_file("lib/my_app_web/components/core.ex", ast).layer == :component
    end

    test "returns :controller for `use Phoenix.Controller`" do
      ast =
        parse("""
        defmodule MyAppWeb.PageController do
          use Phoenix.Controller, namespace: MyAppWeb
        end
        """)

      assert Phoenix.classify_file("lib/my_app_web/controllers/page_controller.ex", ast).layer ==
               :controller
    end

    test "returns :controller for `use MyAppWeb, :controller`" do
      ast =
        parse("""
        defmodule MyAppWeb.PageController do
          use MyAppWeb, :controller
        end
        """)

      assert Phoenix.classify_file("lib/my_app_web/controllers/page_controller.ex", ast).layer ==
               :controller
    end

    test "returns :router for `use Phoenix.Router`" do
      ast =
        parse("""
        defmodule MyAppWeb.Router do
          use Phoenix.Router
        end
        """)

      assert Phoenix.classify_file("lib/my_app_web/router.ex", ast).layer == :router
    end

    test "returns :schema for `use Ecto.Schema`" do
      ast =
        parse("""
        defmodule MyApp.Accounts.User do
          use Ecto.Schema
          schema "users" do
            field :email, :string
          end
        end
        """)

      assert Phoenix.classify_file("lib/my_app/accounts/user.ex", ast).layer == :schema
    end

    test "returns :migration for `use Ecto.Migration`" do
      ast =
        parse("""
        defmodule MyApp.Repo.Migrations.CreateUsers do
          use Ecto.Migration
          def change, do: :ok
        end
        """)

      assert Phoenix.classify_file("priv/repo/migrations/20260101_create_users.exs", ast).layer ==
               :migration
    end

    test "returns :web for files under _web/ without a more specific marker" do
      ast = parse("defmodule MyAppWeb.Endpoint do\n  def url, do: \"/\"\nend")
      assert Phoenix.classify_file("lib/my_app_web/endpoint.ex", ast).layer == :web
    end

    test "returns :test for files under test/" do
      ast = parse("defmodule MyAppTest do\nend")
      assert Phoenix.classify_file("test/my_app_test.exs", ast).layer == :test
    end

    test "returns :context for ordinary lib modules with no marker" do
      ast =
        parse("""
        defmodule MyApp.Accounts do
          def get_user(id), do: id
        end
        """)

      assert Phoenix.classify_file("lib/my_app/accounts.ex", ast).layer == :context
    end

    test "returns :other for files outside lib/, test/, priv/" do
      ast = parse(":ok")
      assert Phoenix.classify_file("scripts/build.exs", ast).layer == :other
    end
  end

  describe "classify_file/2 — uses map" do
    test "captures `use Phoenix.LiveView` in uses map" do
      ast =
        parse("""
        defmodule MyAppWeb.PageLive do
          use Phoenix.LiveView
        end
        """)

      classification = Phoenix.classify_file("lib/my_app_web/live/page_live.ex", ast)
      assert Map.has_key?(classification.uses, Elixir.Phoenix.LiveView)
    end

    test "captures `use MyAppWeb, :live_view` with role atom" do
      ast =
        parse("""
        defmodule MyAppWeb.PageLive do
          use MyAppWeb, :live_view
        end
        """)

      classification = Phoenix.classify_file("lib/my_app_web/live/page_live.ex", ast)
      assert classification.uses[MyAppWeb] == [:live_view]
    end
  end

  describe "classify_file/2 — embed_templates and callbacks" do
    test "extracts embed_templates path declarations" do
      ast =
        parse("""
        defmodule MyAppWeb.Layouts do
          use Phoenix.Component
          embed_templates "layouts/*"
        end
        """)

      classification = Phoenix.classify_file("lib/my_app_web/components/layouts.ex", ast)
      assert "layouts/*" in classification.embed_templates
    end

    test "exposes impl_callbacks set" do
      ast =
        parse("""
        defmodule MyAppWeb.PageLive do
          use Phoenix.LiveView
          @impl true
          def mount(_, _, socket), do: {:ok, socket}
        end
        """)

      classification = Phoenix.classify_file("lib/my_app_web/live/page_live.ex", ast)
      assert MapSet.member?(classification.impl_callbacks, {:mount, 3})
    end

    test "exposes defimpl_callbacks set" do
      ast =
        parse("""
        defimpl Enumerable, for: MyApp.Bag do
          def count(_), do: {:ok, 0}
          def member?(_, _), do: {:ok, false}
          def reduce(_, acc, _), do: acc
          def slice(_), do: {:error, __MODULE__}
        end
        """)

      classification = Phoenix.classify_file("lib/my_app/bag/enumerable.ex", ast)
      assert MapSet.member?(classification.defimpl_callbacks, {:count, 1})
    end
  end

  describe "operational?/1" do
    test "returns true for :operational and :test layers" do
      assert Phoenix.operational?(%{layer: :operational})
      assert Phoenix.operational?(%{layer: :test})
    end

    test "returns false for ordinary layers" do
      refute Phoenix.operational?(%{layer: :context})
      refute Phoenix.operational?(%{layer: :live_view})
      refute Phoenix.operational?(%{layer: :web})
    end

    test "returns true for :application_root (legitimately wires every layer)" do
      assert Phoenix.operational?(%{layer: :application_root})
    end
  end

  describe "context_for_file/1" do
    test "extracts the context segment from a standard lib/ path" do
      assert Phoenix.context_for_file("lib/myapp/accounts/user.ex") == "Accounts"
    end

    test "camelizes snake-cased context names" do
      assert Phoenix.context_for_file("lib/myapp/order_management/order.ex") == "OrderManagement"
    end

    test "returns nil for paths that don't match the lib/X/Y/ shape" do
      assert Phoenix.context_for_file("config/runtime.exs") == nil
      assert Phoenix.context_for_file("mix.exs") == nil
      assert Phoenix.context_for_file("test/foo_test.exs") == nil
    end

    test "returns nil for shallow lib paths (lib/myapp.ex with no nested context)" do
      assert Phoenix.context_for_file("lib/myapp.ex") == nil
    end
  end
end
