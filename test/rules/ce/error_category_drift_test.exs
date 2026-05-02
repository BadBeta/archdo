defmodule Archdo.Rules.CE.ErrorCategoryDriftTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.CE.ErrorCategoryDrift

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

  describe "CE-48 — error atoms scattered across the codebase" do
    test "fires on synonym error atoms across multiple modules" do
      file_asts = [
        parse("lib/a.ex", ~S"""
        defmodule A do
          def go, do: {:error, :not_found}
        end
        """),
        parse("lib/b.ex", ~S"""
        defmodule B do
          def go, do: {:error, :user_not_found}
        end
        """),
        parse("lib/c.ex", ~S"""
        defmodule C do
          def go, do: {:error, :no_user_found}
        end
        """)
      ]

      diags = ErrorCategoryDrift.analyze_project(file_asts)
      assert Enum.any?(diags, fn d -> d.rule_id == "CE-48" end)
    end

    test "does NOT fire on distinct error atoms (no synonyms)" do
      file_asts = [
        parse("lib/a.ex", ~S"""
        defmodule A do
          def go, do: {:error, :timeout}
        end
        """),
        parse("lib/b.ex", ~S"""
        defmodule B do
          def go, do: {:error, :unauthorized}
        end
        """),
        parse("lib/c.ex", ~S"""
        defmodule C do
          def go, do: {:error, :invalid_input}
        end
        """)
      ]

      assert ErrorCategoryDrift.analyze_project(file_asts) == []
    end

    test "does NOT fire when cluster size < 3" do
      file_asts = [
        parse("lib/a.ex", ~S"""
        defmodule A do
          def go, do: {:error, :not_found}
        end
        """),
        parse("lib/b.ex", ~S"""
        defmodule B do
          def go, do: {:error, :user_not_found}
        end
        """)
      ]

      assert ErrorCategoryDrift.analyze_project(file_asts) == []
    end

    test "does NOT fire when same atom is used canonically (no scatter)" do
      file_asts = [
        parse("lib/a.ex", ~S"""
        defmodule A do
          def go, do: {:error, :not_found}
        end
        """),
        parse("lib/b.ex", ~S"""
        defmodule B do
          def go, do: {:error, :not_found}
        end
        """),
        parse("lib/c.ex", ~S"""
        defmodule C do
          def go, do: {:error, :not_found}
        end
        """)
      ]

      assert ErrorCategoryDrift.analyze_project(file_asts) == []
    end
  end
end
