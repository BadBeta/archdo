defmodule Archdo.Rules.CE.ContractDensitySpecsTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.CE.ContractDensitySpecs

  defp parse(file, code) do
    {:ok, ast} =
      Code.string_to_quoted(code,
        file: file,
        columns: true,
        token_metadata: true,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    {file, ast}
  end

  describe "CE-12 — public API module with low @spec coverage" do
    test "fires on Ecto schema with <80% spec coverage" do
      file_asts = [
        parse("lib/myapp/user.ex", ~S"""
        defmodule MyApp.User do
          use Ecto.Schema

          def name(u), do: u.name
          def email(u), do: u.email
          def display(u), do: name(u) <> " <" <> email(u) <> ">"
          def admin?(u), do: u.role == :admin
          def initials(u), do: String.first(u.name)
        end
        """)
      ]

      diags = ContractDensitySpecs.analyze_project(file_asts)
      assert [diag] = diags
      assert diag.rule_id == "CE-12"
      assert diag.message =~ "MyApp.User"
      assert diag.message =~ "0%" or diag.message =~ "0/5"
    end

    test "does NOT fire on Ecto schema with ≥80% spec coverage" do
      file_asts = [
        parse("lib/myapp/user.ex", ~S"""
        defmodule MyApp.User do
          use Ecto.Schema

          @spec name(map()) :: String.t()
          def name(u), do: u.name
          @spec email(map()) :: String.t()
          def email(u), do: u.email
          @spec display(map()) :: String.t()
          def display(u), do: name(u) <> " <" <> email(u) <> ">"
          @spec admin?(map()) :: boolean()
          def admin?(u), do: u.role == :admin
          @spec initials(map()) :: String.t()
          def initials(u), do: String.first(u.name)
        end
        """)
      ]

      assert ContractDensitySpecs.analyze_project(file_asts) == []
    end

    test "fires on Supervisor module with no specs on public functions" do
      file_asts = [
        parse("lib/myapp/sup.ex", ~S"""
        defmodule MyApp.Sup do
          use Supervisor

          def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)
          def init(_), do: Supervisor.init([], strategy: :one_for_one)
          def restart_child(name), do: Supervisor.restart_child(__MODULE__, name)
          def terminate_child(name), do: Supervisor.terminate_child(__MODULE__, name)
          def which_children(), do: Supervisor.which_children(__MODULE__)
        end
        """)
      ]

      diags = ContractDensitySpecs.analyze_project(file_asts)
      assert [diag] = diags
      assert diag.rule_id == "CE-12"
      assert diag.message =~ "MyApp.Sup"
    end

    test "does NOT fire on non-irreversible module (just a regular helper)" do
      file_asts = [
        parse("lib/myapp/util.ex", ~S"""
        defmodule MyApp.Util do
          def a(x), do: x
          def b(x), do: x * 2
          def c(x), do: x + 1
        end
        """)
      ]

      assert ContractDensitySpecs.analyze_project(file_asts) == []
    end

    test "does NOT fire on @archdo_specs_pending exemption" do
      file_asts = [
        parse("lib/myapp/skipped.ex", ~S"""
        defmodule MyApp.Skipped do
          use Ecto.Schema
          @archdo_specs_pending "WIP — adding specs in #1234"

          def a(u), do: u.a
          def b(u), do: u.b
          def c(u), do: u.c
        end
        """)
      ]

      assert ContractDensitySpecs.analyze_project(file_asts) == []
    end

    test "does NOT fire on module with no public functions (vacuous)" do
      file_asts = [
        parse("lib/myapp/empty.ex", ~S"""
        defmodule MyApp.Empty do
          use Ecto.Schema
          @moduledoc false
        end
        """)
      ]

      assert ContractDensitySpecs.analyze_project(file_asts) == []
    end
  end
end
