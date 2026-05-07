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
  defp analyze(file_asts, opts), do: UnanchoredIsland.analyze_project(file_asts, opts)

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

  describe "library mode — public modules auto-anchored" do
    # In a Hex package every module with a real `@moduledoc """..."""` is
    # reachable by external consumers the analyzer cannot see. Without
    # this carve-out, a published library has no anchors at all (no
    # Phoenix route, no Application supervisor) and every public-API
    # cluster fires CE-31. CE-30 already carries this carve-out; this
    # test guards CE-31 against the same FP class.

    test "does NOT fire on a public-API cluster when library?: true" do
      file_asts = [
        parse(
          """
          defmodule MyLib do
            @moduledoc "Top-level facade."
            def chat(opts), do: MyLib.Api.Chat.completions(opts)
          end
          """,
          "lib/my_lib.ex"
        ),
        parse(
          """
          defmodule MyLib.Api.Chat do
            @moduledoc "Chat API."
            def completions(opts), do: MyLib.Client.post(opts)
          end
          """,
          "lib/my_lib/api/chat.ex"
        ),
        parse(
          """
          defmodule MyLib.Client do
            @moduledoc "HTTP client."
            def post(opts), do: MyLib.Api.Chat.completions(opts)
          end
          """,
          "lib/my_lib/client.ex"
        )
      ]

      assert analyze(file_asts, library?: true) == []
    end

    test "STILL fires on the same cluster when library?: false (app mode)" do
      file_asts = [
        parse(
          """
          defmodule MyApp.Foo do
            @moduledoc "real docs"
            def go, do: MyApp.Bar.run()
          end
          """,
          "lib/my_app/foo.ex"
        ),
        parse(
          """
          defmodule MyApp.Bar do
            @moduledoc "real docs"
            def run, do: MyApp.Foo.go()
          end
          """,
          "lib/my_app/bar.ex"
        )
      ]

      assert [_diag] = analyze(file_asts, library?: false)
    end

    test "fires on @moduledoc-false cluster even in library mode" do
      # In a library, `@moduledoc false` modules are explicitly internal —
      # NOT auto-anchored. A mutually-reachable cluster of internals with
      # no entry from anywhere else SHOULD still flag.
      file_asts = [
        parse(
          """
          defmodule MyLib.Internal.A do
            @moduledoc false
            def go, do: MyLib.Internal.B.run()
          end
          """,
          "lib/my_lib/internal/a.ex"
        ),
        parse(
          """
          defmodule MyLib.Internal.B do
            @moduledoc false
            def run, do: MyLib.Internal.A.go()
          end
          """,
          "lib/my_lib/internal/b.ex"
        )
      ]

      assert [_diag] = analyze(file_asts, library?: true)
    end
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
