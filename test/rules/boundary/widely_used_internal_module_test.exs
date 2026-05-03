defmodule Archdo.Rules.Boundary.WidelyUsedInternalModuleTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Boundary.WidelyUsedInternalModule

  describe "caller_context/1 — pure" do
    test "two-component prefix for nested modules" do
      assert WidelyUsedInternalModule.caller_context("MyApp.Catalog.Product") ==
               "MyApp.Catalog"

      assert WidelyUsedInternalModule.caller_context("MyApp.Rules.OTP.Foo") ==
               "MyApp.Rules"
    end

    test "module itself for two-component names" do
      assert WidelyUsedInternalModule.caller_context("MyApp.AST") == "MyApp.AST"
    end

    test "single-component name returns it unchanged" do
      assert WidelyUsedInternalModule.caller_context("Solo") == "Solo"
    end

    test "Mix.Tasks namespace" do
      assert WidelyUsedInternalModule.caller_context("Mix.Tasks.MyApp.Foo") ==
               "Mix.Tasks"
    end
  end

  describe "analyze_project/1 — fires when a private module is reached by many distinct contexts" do
    test "fires when 3 distinct contexts call into one @moduledoc false module" do
      file_asts = [
        private_module(),
        caller("MyApp.Catalog.Product", "Catalog uses internal", "lib/my_app/catalog/product.ex"),
        caller("MyApp.Orders.Workflow", "Orders uses internal", "lib/my_app/orders/workflow.ex"),
        caller("MyApp.Billing.Charges", "Billing uses internal", "lib/my_app/billing/charges.ex")
      ]

      diags = WidelyUsedInternalModule.analyze_project(file_asts)
      assert length(diags) == 1

      diag = hd(diags)
      assert diag.rule_id == "1.27"
      assert diag.severity == :info
      assert diag.message =~ "MyApp.Internals"
      assert diag.message =~ "3" or diag.message =~ "many" or diag.message =~ "widely"
      # References the new skill section
      detail_text =
        diag.alternatives
        |> Enum.map(& &1.detail)
        |> Enum.join(" ")

      assert detail_text =~ "shared" or detail_text =~ "promote" or detail_text =~ "facade"
    end

    test "does NOT fire with only 2 distinct contexts" do
      file_asts = [
        private_module(),
        caller("MyApp.Catalog.Product", "lib/my_app/catalog/product.ex"),
        caller("MyApp.Orders.Workflow", "lib/my_app/orders/workflow.ex")
      ]

      assert WidelyUsedInternalModule.analyze_project(file_asts) == []
    end

    test "multiple callers from the SAME context count as one context" do
      file_asts = [
        private_module(),
        caller("MyApp.Catalog.A", "lib/my_app/catalog/a.ex"),
        caller("MyApp.Catalog.B", "lib/my_app/catalog/b.ex"),
        caller("MyApp.Catalog.C", "lib/my_app/catalog/c.ex"),
        caller("MyApp.Catalog.D", "lib/my_app/catalog/d.ex")
      ]

      assert WidelyUsedInternalModule.analyze_project(file_asts) == []
    end

    test "does NOT fire on modules without @moduledoc false" do
      file_asts = [
        public_module(),
        caller_to("MyApp.PublicHelper", "MyApp.Catalog.Product", "lib/my_app/catalog/product.ex"),
        caller_to("MyApp.PublicHelper", "MyApp.Orders.Workflow", "lib/my_app/orders/workflow.ex"),
        caller_to("MyApp.PublicHelper", "MyApp.Billing.Charges", "lib/my_app/billing/charges.ex")
      ]

      assert WidelyUsedInternalModule.analyze_project(file_asts) == []
    end

    test "skips test files when counting caller contexts" do
      file_asts = [
        private_module(),
        caller("MyApp.Catalog.X", "lib/my_app/catalog/x.ex"),
        caller("MyApp.Orders.Y", "lib/my_app/orders/y.ex"),
        # Test files don't count toward the threshold
        caller("MyApp.Billing.Z", "test/my_app/billing/z_test.exs")
      ]

      assert WidelyUsedInternalModule.analyze_project(file_asts) == []
    end

    test "fires once per private module, not per caller" do
      file_asts = [
        private_module(),
        caller("MyApp.A.X", "lib/my_app/a/x.ex"),
        caller("MyApp.B.Y", "lib/my_app/b/y.ex"),
        caller("MyApp.C.Z", "lib/my_app/c/z.ex"),
        caller("MyApp.D.W", "lib/my_app/d/w.ex")
      ]

      diags = WidelyUsedInternalModule.analyze_project(file_asts)
      assert length(diags) == 1
      assert hd(diags).context.caller_context_count >= 3
    end
  end

  describe "id/0 and description/0" do
    test "rule id is 1.27" do
      assert WidelyUsedInternalModule.id() == "1.27"
    end

    test "description mentions widely-used / public-API" do
      desc = WidelyUsedInternalModule.description()
      assert desc =~ "internal" or desc =~ "private" or desc =~ "moduledoc"
    end
  end

  # --- helpers ---

  defp private_module do
    parse(
      """
      defmodule MyApp.Internals do
        @moduledoc false
        def helper, do: :ok
      end
      """,
      "lib/my_app/internals.ex"
    )
  end

  defp public_module do
    parse(
      """
      defmodule MyApp.PublicHelper do
        @moduledoc "Public helper used everywhere."
        def helper, do: :ok
      end
      """,
      "lib/my_app/public_helper.ex"
    )
  end

  defp caller(module_name, file), do: caller(module_name, "calls internal helper", file)

  defp caller(module_name, _label, file) do
    caller_to("MyApp.Internals", module_name, file)
  end

  defp caller_to(target_module, caller_module_name, file) do
    parse(
      """
      defmodule #{caller_module_name} do
        def use_it, do: #{target_module}.helper()
      end
      """,
      file
    )
  end

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
end
