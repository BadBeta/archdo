defmodule Archdo.Rules.Boundary.PrivateModuleCallsTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Boundary.PrivateModuleCalls

  defp parse(code, file) do
    {:ok, ast} =
      Code.string_to_quoted(code,
        file: file,
        columns: true,
        token_metadata: true,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    {file, ast}
  end

  describe "analyze_project/1" do
    test "fires when a module from another namespace calls into a @moduledoc false module" do
      file_asts = [
        parse(
          """
          defmodule MyApp.Catalog.Internals do
            @moduledoc false
            def secret_helper, do: :ok
          end
          """,
          "lib/my_app/catalog/internals.ex"
        ),
        parse(
          """
          defmodule MyApp.Orders do
            def use_secret, do: MyApp.Catalog.Internals.secret_helper()
          end
          """,
          "lib/my_app/orders.ex"
        )
      ]

      diags = PrivateModuleCalls.analyze_project(file_asts)
      assert length(diags) == 1
      diag = hd(diags)
      assert diag.rule_id == "2.3"
      assert diag.severity == :warning
      assert diag.message =~ "MyApp.Orders"
      assert diag.message =~ "MyApp.Catalog.Internals"
      assert diag.message =~ "moduledoc"
    end

    test "does NOT fire when caller and target share the same parent namespace" do
      # MyApp.Catalog calling MyApp.Catalog.Internals is fine — the parent context
      # owns its own internals.
      file_asts = [
        parse(
          """
          defmodule MyApp.Catalog.Internals do
            @moduledoc false
            def secret_helper, do: :ok
          end
          """,
          "lib/my_app/catalog/internals.ex"
        ),
        parse(
          """
          defmodule MyApp.Catalog do
            def public_api, do: MyApp.Catalog.Internals.secret_helper()
          end
          """,
          "lib/my_app/catalog.ex"
        )
      ]

      assert PrivateModuleCalls.analyze_project(file_asts) == []
    end

    test "does NOT fire when target is not @moduledoc false" do
      file_asts = [
        parse(
          """
          defmodule MyApp.Catalog.Internals do
            @moduledoc "Public-by-design helper."
            def helper, do: :ok
          end
          """,
          "lib/my_app/catalog/internals.ex"
        ),
        parse(
          """
          defmodule MyApp.Orders do
            def use, do: MyApp.Catalog.Internals.helper()
          end
          """,
          "lib/my_app/orders.ex"
        )
      ]

      assert PrivateModuleCalls.analyze_project(file_asts) == []
    end

    test "skips test files (callers in test/ are out of scope)" do
      file_asts = [
        parse(
          """
          defmodule MyApp.Catalog.Internals do
            @moduledoc false
            def helper, do: :ok
          end
          """,
          "lib/my_app/catalog/internals.ex"
        ),
        parse(
          """
          defmodule MyApp.OrdersTest do
            use ExUnit.Case
            test "x" do
              MyApp.Catalog.Internals.helper()
            end
          end
          """,
          "test/my_app/orders_test.exs"
        )
      ]

      assert PrivateModuleCalls.analyze_project(file_asts) == []
    end

    test "deduplicates multiple call sites from the same caller into the same private module" do
      file_asts = [
        parse(
          """
          defmodule MyApp.Catalog.Internals do
            @moduledoc false
            def a, do: :a
            def b, do: :b
          end
          """,
          "lib/my_app/catalog/internals.ex"
        ),
        parse(
          """
          defmodule MyApp.Orders do
            def x, do: MyApp.Catalog.Internals.a()
            def y, do: MyApp.Catalog.Internals.b()
          end
          """,
          "lib/my_app/orders.ex"
        )
      ]

      diags = PrivateModuleCalls.analyze_project(file_asts)
      # One per (source, target) pair, regardless of call-site count.
      assert length(diags) == 1
    end
  end

  describe "id/0 and description/0" do
    test "rule id is 2.3" do
      assert PrivateModuleCalls.id() == "2.3"
    end

    test "description mentions @moduledoc false" do
      desc = PrivateModuleCalls.description()
      assert desc =~ "moduledoc" or desc =~ "private"
    end
  end
end
