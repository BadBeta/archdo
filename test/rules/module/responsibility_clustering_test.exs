defmodule Archdo.Rules.Module.ResponsibilityClusteringTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Module.ResponsibilityClustering

  defp analyze(code, file \\ "lib/my_app/service.ex") do
    {:ok, ast} = Code.string_to_quoted(code, file: file, columns: true, token_metadata: true)
    ResponsibilityClustering.analyze(file, ast, [])
  end

  test "flags module with two independent responsibility clusters" do
    diags = analyze("""
      defmodule MyApp.Service do
        # Cluster 1: user management — two functions sharing a helper
        def create_user(attrs), do: user_repo(attrs)
        def delete_user(id), do: user_repo(id)
        defp user_repo(x), do: x

        # Cluster 2: billing — two functions sharing a different helper
        def create_invoice(data), do: invoice_repo(data)
        def send_invoice(invoice), do: invoice_repo(invoice)
        defp invoice_repo(x), do: x
      end
    """)

    assert length(diags) == 1
    [diag] = diags
    assert diag.rule_id == "6.12"
    assert diag.severity == :warning
    assert diag.message =~ "2 independent function clusters"
  end

  test "allows module where all functions share helpers" do
    diags = analyze("""
      defmodule MyApp.Service do
        def create(attrs), do: validate(attrs)
        def update(attrs), do: validate(attrs)
        def delete(id), do: validate(id)
        def get(id), do: validate(id)
        defp validate(x), do: x
      end
    """)

    assert diags == []
  end

  test "skips modules with fewer than 4 public functions" do
    diags = analyze("""
      defmodule MyApp.Small do
        def foo, do: helper_a()
        def bar, do: helper_b()
        defp helper_a, do: :a
        defp helper_b, do: :b
      end
    """)

    assert diags == []
  end

  test "skips test files" do
    diags = analyze("""
      defmodule MyApp.ServiceTest do
        def test_a, do: helper_a()
        def test_b, do: helper_b()
        def test_c, do: helper_a()
        def test_d, do: helper_b()
        defp helper_a, do: :a
        defp helper_b, do: :b
      end
    """, "test/my_app/service_test.exs")

    assert diags == []
  end

  test "ignores clusters with only 1 function" do
    # 3 connected + 1 isolated = only 1 significant cluster
    diags = analyze("""
      defmodule MyApp.Service do
        def a, do: shared()
        def b, do: shared()
        def c, do: shared()
        def lonely, do: :alone
        defp shared, do: :ok
      end
    """)

    assert diags == []
  end

  test "detects three independent clusters" do
    diags = analyze("""
      defmodule MyApp.GodModule do
        def user_create(a), do: user_helper(a)
        def user_delete(a), do: user_helper(a)
        defp user_helper(a), do: a

        def order_create(a), do: order_helper(a)
        def order_ship(a), do: order_helper(a)
        defp order_helper(a), do: a

        def report_gen(a), do: report_helper(a)
        def report_send(a), do: report_helper(a)
        defp report_helper(a), do: a
      end
    """)

    assert length(diags) == 1
    assert hd(diags).message =~ "3 independent function clusters"
  end
end
