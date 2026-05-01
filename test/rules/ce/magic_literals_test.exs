defmodule Archdo.Rules.CE.MagicLiteralsTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.CE.MagicLiterals

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

  defp analyze(file_asts), do: MagicLiterals.analyze_project(file_asts)

  test "fires on magic atom used in comparisons across two modules" do
    a =
      parse(
        """
        defmodule MyApp.Workflow do
          def open?(state), do: state == :pending_approval
        end
        """,
        "lib/my_app/workflow.ex"
      )

    b =
      parse(
        """
        defmodule MyApp.Renderer do
          def style(state), do: if state == :pending_approval, do: "amber", else: "green"
        end
        """,
        "lib/my_app/renderer.ex"
      )

    diags = analyze([a, b])
    assert length(diags) == 1
    assert hd(diags).rule_id == "CE-17"
    assert hd(diags).message =~ ":pending_approval"
  end

  test "does NOT fire when the magic value lives in only one module" do
    a =
      parse(
        """
        defmodule MyApp.Single do
          def go(s), do: s == :only_here
        end
        """,
        "lib/my_app/single.ex"
      )

    assert analyze([a]) == []
  end

  test "does NOT fire on stable numeric constants (0, 1, -1, 200, 80, 443)" do
    # Common standalone numbers that don't merit symbolic naming.
    a =
      parse(
        """
        defmodule MyApp.Health do
          def ok?(s), do: s == 200
        end
        """,
        "lib/my_app/health.ex"
      )

    b =
      parse(
        """
        defmodule MyApp.Probe do
          def healthy?(s), do: s == 200
        end
        """,
        "lib/my_app/probe.ex"
      )

    assert analyze([a, b]) == []
  end

  test "does NOT fire on string literals used as Map keys (incidental)" do
    # `Map.get(map, "name")` is just a key lookup, not a magic-meaning constant.
    a =
      parse(
        """
        defmodule MyApp.A do
          def n(m), do: Map.get(m, "name")
        end
        """,
        "lib/my_app/a.ex"
      )

    b =
      parse(
        """
        defmodule MyApp.B do
          def n(m), do: Map.get(m, "name")
        end
        """,
        "lib/my_app/b.ex"
      )

    assert analyze([a, b]) == []
  end

  test "fires on magic atom appearing as a status field assignment in two modules" do
    a =
      parse(
        """
        defmodule MyApp.Creator do
          def make, do: %{status: :awaiting_review}
        end
        """,
        "lib/my_app/creator.ex"
      )

    b =
      parse(
        """
        defmodule MyApp.Updater do
          def reset(rec), do: %{rec | status: :awaiting_review}
        end
        """,
        "lib/my_app/updater.ex"
      )

    diags = analyze([a, b])
    assert length(diags) == 1
    assert hd(diags).message =~ ":awaiting_review"
  end
end
