defmodule Archdo.Rules.CE.ReturnShapeDriftTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.CE.ReturnShapeDrift

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

  describe "CE-47 — bang function without non-bang sibling" do
    test "fires on bang function lacking non-bang sibling" do
      file_asts = [
        parse("lib/myapp/accounts.ex", ~S"""
        defmodule MyApp.Accounts do
          def get_user(id), do: do_get(id)
          def list_users(), do: do_list()
          def create_user!(attrs), do: do_create!(attrs)
        end
        """)
      ]

      diags = ReturnShapeDrift.analyze_project(file_asts)

      assert Enum.any?(diags, fn d ->
               d.rule_id == "CE-47" and d.message =~ "create_user!"
             end)
    end

    test "does NOT fire when both bang and non-bang exist" do
      file_asts = [
        parse("lib/myapp/accounts.ex", ~S"""
        defmodule MyApp.Accounts do
          def get_user(id), do: do_get(id)
          def get_user!(id), do: do_get!(id)
        end
        """)
      ]

      assert ReturnShapeDrift.analyze_project(file_asts) == []
    end

    test "does NOT fire when ALL functions are bang (consistent style)" do
      # If a context is all-bang, that's a deliberate convention — do not flag
      file_asts = [
        parse("lib/myapp/seeds.ex", ~S"""
        defmodule MyApp.Seeds do
          def insert_user!(attrs), do: do_a!(attrs)
          def insert_org!(attrs), do: do_b!(attrs)
          def insert_team!(attrs), do: do_c!(attrs)
        end
        """)
      ]

      assert ReturnShapeDrift.analyze_project(file_asts) == []
    end

    test "does NOT fire on a regular helper module (no public API context)" do
      # Single-function modules are not "context" enough to flag
      file_asts = [
        parse("lib/myapp/util.ex", ~S"""
        defmodule MyApp.Util do
          def go!(x), do: do_go(x)
        end
        """)
      ]

      assert ReturnShapeDrift.analyze_project(file_asts) == []
    end
  end
end
