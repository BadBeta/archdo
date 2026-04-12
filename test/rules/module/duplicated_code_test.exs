defmodule Archdo.Rules.Module.DuplicatedCodeTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Module.DuplicatedCode

  defp parse(code, file) do
    {:ok, ast} = Code.string_to_quoted(code, file: file, columns: true)
    {file, ast}
  end

  describe "duplicate detection" do
    test "detects structurally identical functions across files" do
      file1 = parse(~S"""
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
      """, "lib/orders.ex")

      file2 = parse(~S"""
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
      """, "lib/invoices.ex")

      diags = DuplicatedCode.analyze_project([file1, file2])
      assert length(diags) >= 1

      main = Enum.find(diags, &(&1.message =~ "compute_amount" or &1.message =~ "calculate_total"))
      assert main
      assert main.severity == :warning
    end

    test "ignores standard callbacks" do
      file1 = parse(~S"""
      defmodule MyApp.ServerA do
        use GenServer
        def init(_), do: {:ok, %{}}
        def handle_call(:foo, _from, state), do: {:reply, :ok, state}
      end
      """, "lib/server_a.ex")

      file2 = parse(~S"""
      defmodule MyApp.ServerB do
        use GenServer
        def init(_), do: {:ok, %{}}
        def handle_call(:foo, _from, state), do: {:reply, :ok, state}
      end
      """, "lib/server_b.ex")

      diags = DuplicatedCode.analyze_project([file1, file2])
      assert diags == []
    end

    test "ignores trivial small functions" do
      file1 = parse(~S"""
      defmodule MyApp.A do
        def foo, do: :ok
      end
      """, "lib/a.ex")

      file2 = parse(~S"""
      defmodule MyApp.B do
        def foo, do: :ok
      end
      """, "lib/b.ex")

      diags = DuplicatedCode.analyze_project([file1, file2])
      assert diags == []
    end

    test "ignores duplicates within the same file" do
      file1 = parse(~S"""
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
      """, "lib/a.ex")

      diags = DuplicatedCode.analyze_project([file1])
      # Same-file duplicates are caller's choice (could be intentional)
      assert diags == []
    end

    test "ignores test files" do
      file1 = parse(~S"""
      defmodule MyApp.UserTest do
        def setup_user(id) do
          %User{id: id, name: "Test", email: "test@example.com", active: true}
          |> Repo.insert!()
          |> Map.put(:foo, :bar)
        end
      end
      """, "test/user_test.exs")

      file2 = parse(~S"""
      defmodule MyApp.AccountTest do
        def setup_account(id) do
          %Account{id: id, name: "Test", email: "test@example.com", active: true}
          |> Repo.insert!()
          |> Map.put(:foo, :bar)
        end
      end
      """, "test/account_test.exs")

      diags = DuplicatedCode.analyze_project([file1, file2])
      assert diags == []
    end
  end
end
