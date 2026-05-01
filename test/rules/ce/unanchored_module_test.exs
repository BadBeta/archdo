defmodule Archdo.Rules.CE.UnanchoredModuleTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.CE.UnanchoredModule

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

  defp analyze(file_asts), do: UnanchoredModule.analyze_project(file_asts)

  test "fires on a module not reachable from any anchor" do
    file_asts = [
      parse(
        """
        defmodule MyApp.Application do
          use Application
          def start(_, _), do: Supervisor.start_link([MyApp.Repo], strategy: :one_for_one)
        end
        """,
        "lib/my_app/application.ex"
      ),
      parse(
        """
        defmodule MyApp.Repo do
          def get(_, _), do: nil
        end
        """,
        "lib/my_app/repo.ex"
      ),
      parse(
        """
        defmodule MyApp.LeftoverScaffold do
          def lonely, do: :unreachable
        end
        """,
        "lib/my_app/leftover_scaffold.ex"
      )
    ]

    diags = analyze(file_asts)
    assert length(diags) == 1
    assert hd(diags).rule_id == "CE-30"
    assert hd(diags).message =~ "MyApp.LeftoverScaffold"
  end

  test "does NOT fire on an anchored module" do
    file_asts = [
      parse(
        """
        defmodule MyApp.Application do
          use Application
          def start(_, _), do: Supervisor.start_link([], strategy: :one_for_one)
        end
        """,
        "lib/my_app/application.ex"
      )
    ]

    assert analyze(file_asts) == []
  end

  test "does NOT fire on a module reachable from an anchor" do
    file_asts = [
      parse(
        """
        defmodule MyApp.Application do
          use Application
          def start(_, _) do
            MyApp.Boot.run()
            Supervisor.start_link([], strategy: :one_for_one)
          end
        end
        """,
        "lib/my_app/application.ex"
      ),
      parse(
        """
        defmodule MyApp.Boot do
          def run, do: MyApp.Helpers.warmup()
        end
        """,
        "lib/my_app/boot.ex"
      ),
      parse(
        """
        defmodule MyApp.Helpers do
          def warmup, do: :ok
        end
        """,
        "lib/my_app/helpers.ex"
      )
    ]

    assert analyze(file_asts) == []
  end

  test "does NOT fire on test files even if they contain orphan modules" do
    # Modules under test/ paths are out of scope — they're driven by
    # ExUnit.run, not the production anchor closure.
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
        defmodule MyApp.HelperTest do
          use ExUnit.Case
          test "pass", do: assert(true)
        end
        """,
        "test/my_app/helper_test.exs"
      )
    ]

    assert analyze(file_asts) == []
  end
end
