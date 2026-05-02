defmodule Archdo.Rules.Module.DuplicatedCodeTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Module.DuplicatedCode

  defp parse(code, file) do
    {:ok, ast} = Code.string_to_quoted(code, file: file, columns: true)
    {file, ast}
  end

  describe "duplicate detection" do
    test "detects structurally identical functions across files" do
      file1 =
        parse(
          ~S"""
          defmodule MyApp.Orders do
            def calculate_total(items) do
              items
              |> Enum.map(fn item -> item.price * item.quantity end)
              |> Enum.sum()
              |> apply_tax(0.08)
              |> round_to_cents()
            end

            defp apply_tax(amount, rate), do: amount * (1 + rate)
            defp round_to_cents(amount), do: Float.round(amount, 2)
          end
          """,
          "lib/orders.ex"
        )

      file2 =
        parse(
          ~S"""
          defmodule MyApp.Invoices do
            def compute_amount(line_items) do
              line_items
              |> Enum.map(fn line -> line.price * line.quantity end)
              |> Enum.sum()
              |> apply_tax(0.08)
              |> round_to_cents()
            end

            defp apply_tax(value, percent), do: value * (1 + percent)
            defp round_to_cents(value), do: Float.round(value, 2)
          end
          """,
          "lib/invoices.ex"
        )

      diags = DuplicatedCode.analyze_project([file1, file2])
      assert [_ | _] = diags

      main =
        Enum.find(diags, &(&1.message =~ "compute_amount" or &1.message =~ "calculate_total"))

      assert main
      assert main.severity == :warning
    end

    test "ignores standard callbacks" do
      file1 =
        parse(
          ~S"""
          defmodule MyApp.ServerA do
            use GenServer
            def init(_), do: {:ok, %{}}
            def handle_call(:foo, _from, state), do: {:reply, :ok, state}
          end
          """,
          "lib/server_a.ex"
        )

      file2 =
        parse(
          ~S"""
          defmodule MyApp.ServerB do
            use GenServer
            def init(_), do: {:ok, %{}}
            def handle_call(:foo, _from, state), do: {:reply, :ok, state}
          end
          """,
          "lib/server_b.ex"
        )

      diags = DuplicatedCode.analyze_project([file1, file2])
      assert diags == []
    end

    test "ignores trivial small functions" do
      file1 =
        parse(
          ~S"""
          defmodule MyApp.A do
            def foo, do: :ok
          end
          """,
          "lib/a.ex"
        )

      file2 =
        parse(
          ~S"""
          defmodule MyApp.B do
            def foo, do: :ok
          end
          """,
          "lib/b.ex"
        )

      diags = DuplicatedCode.analyze_project([file1, file2])
      assert diags == []
    end

    test "ignores duplicates within the same file" do
      file1 =
        parse(
          ~S"""
          defmodule MyApp.A do
            def big_one(items) do
              items
              |> Enum.map(fn x -> x * x end)
              |> Enum.sum()
              |> Kernel.+(100)
              |> Kernel.*(2)
            end

            def big_two(stuff) do
              stuff
              |> Enum.map(fn x -> x * x end)
              |> Enum.sum()
              |> Kernel.+(100)
              |> Kernel.*(2)
            end
          end
          """,
          "lib/a.ex"
        )

      diags = DuplicatedCode.analyze_project([file1])
      # Same-file duplicates are caller's choice (could be intentional)
      assert diags == []
    end

    test "ignores test files" do
      file1 =
        parse(
          ~S"""
          defmodule MyApp.UserTest do
            def setup_user(id) do
              %User{id: id, name: "Test", email: "test@example.com", active: true}
              |> Repo.insert!()
              |> Map.put(:foo, :bar)
            end
          end
          """,
          "test/user_test.exs"
        )

      file2 =
        parse(
          ~S"""
          defmodule MyApp.AccountTest do
            def setup_account(id) do
              %Account{id: id, name: "Test", email: "test@example.com", active: true}
              |> Repo.insert!()
              |> Map.put(:foo, :bar)
            end
          end
          """,
          "test/account_test.exs"
        )

      diags = DuplicatedCode.analyze_project([file1, file2])
      assert diags == []
    end
  end

  describe "umbrella sibling clones (D12)" do
    test "downgrades to :info when clones live in different umbrella sibling apps" do
      # Same code in two umbrella sibling apps. The duplication is
      # often deliberate (shared schema fields, parallel implementations
      # for different runtime targets); fire as :info, not :warning.
      shared_body = ~S"""
        def calculate_total(items) do
          items
          |> Enum.map(fn item -> item.price * item.quantity end)
          |> Enum.sum()
          |> apply_tax(0.08)
          |> round_to_cents()
        end

        defp apply_tax(amount, rate), do: amount * (1 + rate)
        defp round_to_cents(amount), do: Float.round(amount, 2)
      """

      file1 =
        parse(
          "defmodule Api.Orders do\n#{shared_body}end\n",
          "apps/api/lib/api/orders.ex"
        )

      file2 =
        parse(
          "defmodule Edge.Orders do\n#{shared_body}end\n",
          "apps/edge/lib/edge/orders.ex"
        )

      diags = DuplicatedCode.analyze_project([file1, file2])
      assert [diag | _] = diags
      assert diag.severity == :info, "Expected :info, got #{diag.severity}"
    end

    test "keeps :warning when both clones live in the same umbrella sibling app" do
      shared_body = ~S"""
        def calculate_total(items) do
          items
          |> Enum.map(fn item -> item.price * item.quantity end)
          |> Enum.sum()
          |> apply_tax(0.08)
          |> round_to_cents()
        end

        defp apply_tax(amount, rate), do: amount * (1 + rate)
        defp round_to_cents(amount), do: Float.round(amount, 2)
      """

      file1 =
        parse(
          "defmodule Api.Orders do\n#{shared_body}end\n",
          "apps/api/lib/api/orders.ex"
        )

      file2 =
        parse(
          "defmodule Api.Invoices do\n#{shared_body}end\n",
          "apps/api/lib/api/invoices.ex"
        )

      diags = DuplicatedCode.analyze_project([file1, file2])
      assert [diag | _] = diags
      assert diag.severity == :warning
    end

    test "keeps :warning for non-umbrella projects (no apps/ prefix)" do
      shared_body = ~S"""
        def calculate_total(items) do
          items
          |> Enum.map(fn item -> item.price * item.quantity end)
          |> Enum.sum()
          |> apply_tax(0.08)
          |> round_to_cents()
        end

        defp apply_tax(amount, rate), do: amount * (1 + rate)
        defp round_to_cents(amount), do: Float.round(amount, 2)
      """

      file1 =
        parse(
          "defmodule MyApp.Orders do\n#{shared_body}end\n",
          "lib/my_app/orders.ex"
        )

      file2 =
        parse(
          "defmodule MyApp.Invoices do\n#{shared_body}end\n",
          "lib/my_app/invoices.ex"
        )

      diags = DuplicatedCode.analyze_project([file1, file2])
      assert [diag | _] = diags
      assert diag.severity == :warning
    end
  end
end
