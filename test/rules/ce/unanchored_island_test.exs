defmodule Archdo.Rules.CE.UnanchoredIslandTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.CE.UnanchoredIsland

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

  defp analyze(file_asts), do: UnanchoredIsland.analyze_project(file_asts)

  test "fires on a 2-module mutual cycle outside any anchor closure" do
    file_asts = [
      parse(
        """
        defmodule MyApp.Application do
          use Application
          def start(_, _), do: Supervisor.start_link([], strategy: :one_for_one)
        end
        """,
        "lib/my_app/application.ex"
      ),
      # Two modules that reference each other but nothing else references them.
      parse(
        """
        defmodule MyApp.Island.A do
          def go, do: MyApp.Island.B.come()
        end
        """,
        "lib/my_app/island/a.ex"
      ),
      parse(
        """
        defmodule MyApp.Island.B do
          def come, do: MyApp.Island.A.go()
        end
        """,
        "lib/my_app/island/b.ex"
      )
    ]

    diags = analyze(file_asts)
    # One finding for the cluster (not one per module).
    assert length(diags) == 1
    assert hd(diags).rule_id == "CE-31"
    assert hd(diags).message =~ "MyApp.Island.A"
    assert hd(diags).message =~ "MyApp.Island.B"
  end

  test "does NOT fire on a cycle that includes an anchored module" do
    file_asts = [
      parse(
        """
        defmodule MyApp.Application do
          use Application
          def start(_, _) do
            MyApp.Cycle.A.go()
            Supervisor.start_link([], strategy: :one_for_one)
          end
        end
        """,
        "lib/my_app/application.ex"
      ),
      parse(
        """
        defmodule MyApp.Cycle.A do
          def go, do: MyApp.Cycle.B.come()
        end
        """,
        "lib/my_app/cycle/a.ex"
      ),
      parse(
        """
        defmodule MyApp.Cycle.B do
          def come, do: MyApp.Cycle.A.go()
        end
        """,
        "lib/my_app/cycle/b.ex"
      )
    ]

    # Application reaches Cycle.A; A and B are mutually-reachable from
    # the anchor closure. CE-31 should not fire (CE-30 also clean).
    assert analyze(file_asts) == []
  end

  test "does NOT fire on a single isolated module (CE-30's job, not CE-31)" do
    file_asts = [
      parse(
        """
        defmodule MyApp.Application do
          use Application
          def start(_, _), do: Supervisor.start_link([], strategy: :one_for_one)
        end
        """,
        "lib/my_app/application.ex"
      ),
      parse(
        """
        defmodule MyApp.Lonely do
          def hello, do: :world
        end
        """,
        "lib/my_app/lonely.ex"
      )
    ]

    # Lonely is unanchored but not part of a multi-module cluster.
    # CE-30 catches it; CE-31 leaves it alone.
    assert analyze(file_asts) == []
  end
end
