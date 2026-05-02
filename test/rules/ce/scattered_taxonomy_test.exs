defmodule Archdo.Rules.CE.ScatteredTaxonomyTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.CE.ScatteredTaxonomy

  defp parse(file, code) do
    {:ok, ast} = Code.string_to_quoted(code, file: file)
    {file, ast}
  end

  describe "CE-26 — scattered cross-cutting taxonomy" do
    test "fires when telemetry events are spelled inconsistently across modules" do
      file_asts = [
        parse("lib/a.ex", ~S"""
        defmodule A do
          def go(x), do: :telemetry.execute([:user, :created], %{}, %{x: x})
        end
        """),
        parse("lib/b.ex", ~S"""
        defmodule B do
          def go(x), do: :telemetry.execute([:users, :create], %{}, %{x: x})
        end
        """),
        parse("lib/c.ex", ~S"""
        defmodule C do
          def go(x), do: :telemetry.execute([:user, :create], %{}, %{x: x})
        end
        """)
      ]

      diags = ScatteredTaxonomy.analyze_project(file_asts)
      assert length(diags) >= 1
      assert hd(diags).rule_id == "CE-26"
    end

    test "fires when Logger keys are spelled inconsistently across modules" do
      file_asts = [
        parse("lib/a.ex", ~S"""
        defmodule A do
          def go, do: Logger.info("user_created")
        end
        """),
        parse("lib/b.ex", ~S"""
        defmodule B do
          def go, do: Logger.info("created_user")
        end
        """),
        parse("lib/c.ex", ~S"""
        defmodule C do
          def go, do: Logger.info("user.create")
        end
        """)
      ]

      diags = ScatteredTaxonomy.analyze_project(file_asts)
      assert Enum.any?(diags, &(&1.rule_id == "CE-26"))
    end

    test "does NOT fire when event names are distinct (no scatter)" do
      file_asts = [
        parse("lib/a.ex", ~S"""
        defmodule A do
          def go, do: :telemetry.execute([:user, :created], %{}, %{})
        end
        """),
        parse("lib/b.ex", ~S"""
        defmodule B do
          def go, do: :telemetry.execute([:order, :placed], %{}, %{})
        end
        """),
        parse("lib/c.ex", ~S"""
        defmodule C do
          def go, do: :telemetry.execute([:payment, :charged], %{}, %{})
        end
        """)
      ]

      diags = ScatteredTaxonomy.analyze_project(file_asts)
      assert diags == []
    end

    test "does NOT fire when cluster size < 3" do
      file_asts = [
        parse("lib/a.ex", ~S"""
        defmodule A do
          def go, do: :telemetry.execute([:user, :created], %{}, %{})
        end
        """),
        parse("lib/b.ex", ~S"""
        defmodule B do
          def go, do: :telemetry.execute([:user, :create], %{}, %{})
        end
        """)
      ]

      diags = ScatteredTaxonomy.analyze_project(file_asts)
      assert diags == []
    end

    test "groups identical names but does not flag (similarity = exact match, not synonym)" do
      file_asts = [
        parse("lib/a.ex", ~S"""
        defmodule A do
          def go, do: :telemetry.execute([:user, :created], %{}, %{})
        end
        """),
        parse("lib/b.ex", ~S"""
        defmodule B do
          def go, do: :telemetry.execute([:user, :created], %{}, %{})
        end
        """),
        parse("lib/c.ex", ~S"""
        defmodule C do
          def go, do: :telemetry.execute([:user, :created], %{}, %{})
        end
        """)
      ]

      # Same name across 3 modules is canonical, not scattered
      diags = ScatteredTaxonomy.analyze_project(file_asts)
      assert diags == []
    end
  end
end
