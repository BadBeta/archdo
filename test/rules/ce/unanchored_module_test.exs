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

  describe "cross-suppression via compiled-graph reachability" do
    setup do
      # Standard fixture: an Application + an apparently-orphan module
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
          defmodule MyApp.MacroDriven do
            def callback, do: :reached_via_use_clause
          end
          """,
          "lib/my_app/macro_driven.ex"
        )
      ]

      %{file_asts: file_asts}
    end

    test "without compiled_reached_modules in opts, fires (AST-only mode)", %{
      file_asts: file_asts
    } do
      diags = UnanchoredModule.analyze_project(file_asts)
      assert length(diags) == 1
      assert hd(diags).message =~ "MyApp.MacroDriven"
    end

    test "with compiled_reached_modules containing the module, does NOT fire", %{
      file_asts: file_asts
    } do
      reached = MapSet.new([MyApp.MacroDriven])
      opts = [compiled_reached_modules: reached]

      assert UnanchoredModule.analyze_project(file_asts, opts) == []
    end

    test "with compiled_reached_modules NOT containing the module, still fires", %{
      file_asts: file_asts
    } do
      reached = MapSet.new([SomeOther.Module])
      opts = [compiled_reached_modules: reached]

      diags = UnanchoredModule.analyze_project(file_asts, opts)
      assert length(diags) == 1
      assert hd(diags).message =~ "MyApp.MacroDriven"
    end

    test "with empty MapSet, behaves like no compiled data (still fires)", %{
      file_asts: file_asts
    } do
      opts = [compiled_reached_modules: MapSet.new()]

      diags = UnanchoredModule.analyze_project(file_asts, opts)
      assert length(diags) == 1
    end
  end

  describe "diagnostic content elevates the macro caveat" do
    test "message references macro / dynamic-dispatch limitation" do
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
          defmodule MyApp.Maybe do
            def hi, do: :hi
          end
          """,
          "lib/my_app/maybe.ex"
        )
      ]

      [diag] = UnanchoredModule.analyze_project(file_asts)
      # Message itself (not just `why`) should warn about macro / dynamic
      # blind spots so the user sees it without expanding the diagnostic.
      assert diag.message =~ "macro" or diag.message =~ "dynamic"
    end

    test "library projects: public modules are anchors (validated against Floki)" do
      # In a project with `package/0` in mix.exs (a Hex-publishable
      # library), there's no Phoenix route / Mix.Task / Application
      # to anchor from — the PUBLIC API itself is the anchor set.
      # Every module not marked `@moduledoc false` IS reachable by
      # external library consumers. CE-30's AST closure walk has no
      # signal here without library awareness.
      #
      # Validated against Floki: 30 CE-30 findings before, all on
      # public lib modules that are part of the API surface.
      #
      # The runner threads `library?: true` via opts when it detects
      # mix.exs has package/0. Tests pass it explicitly.
      public =
        parse(
          """
          defmodule MyLib do
            @moduledoc "Public API"
            def parse(input), do: MyLib.Parser.parse(input)
          end
          """,
          "lib/mylib.ex"
        )

      internal_reached =
        parse(
          """
          defmodule MyLib.Parser do
            @moduledoc false
            def parse(input), do: input
          end
          """,
          "lib/mylib/parser.ex"
        )

      internal_orphan =
        parse(
          """
          defmodule MyLib.Orphan do
            @moduledoc false
            def stale, do: :stale
          end
          """,
          "lib/mylib/orphan.ex"
        )

      diags =
        UnanchoredModule.analyze_project(
          [public, internal_reached, internal_orphan],
          library?: true
        )

      flagged = Enum.map(diags, & &1.context.module)

      refute "MyLib" in flagged, "public lib module should be anchored by being public API"

      refute "MyLib.Parser" in flagged,
             "internal module reached from public should be anchored transitively"

      assert "MyLib.Orphan" in flagged,
             "internal module unreached from any public module should still flag"
    end

    test "library projects: behaviour-implementor modules are anchored even when @moduledoc false" do
      # Pluggable adapter modules (Floki.HTMLParser.FastHtml /
      # Html5ever / Mochiweb shape) are @moduledoc false but reached
      # via runtime config — invisible to AST analysis. They DO
      # declare @behaviour Foo where Foo is a project-defined
      # behaviour. Anchor them by virtue of implementing a project
      # behaviour.
      behaviour =
        parse(
          """
          defmodule MyLib.Parser do
            @callback parse(binary()) :: term()
          end
          """,
          "lib/mylib/parser.ex"
        )

      adapter =
        parse(
          """
          defmodule MyLib.Parser.Fast do
            @moduledoc false
            @behaviour MyLib.Parser
            def parse(input), do: input
          end
          """,
          "lib/mylib/parser/fast.ex"
        )

      diags =
        UnanchoredModule.analyze_project([behaviour, adapter], library?: true)

      flagged = Enum.map(diags, & &1.context.module)

      refute "MyLib.Parser.Fast" in flagged,
             "behaviour-implementor module reached via runtime config should be anchored"
    end

    test "library projects: behaviour-DEFINITION module referenced by @behaviour is anchored" do
      # A `@moduledoc false` behaviour module that DEFINES `@callback`s —
      # NOT a directly-called module — is reachable purely as a contract:
      # an anchored implementor declares `@behaviour Foo`, so Foo is part
      # of the implementor's compile-time interface. Deleting Foo would
      # break the implementor. Anchor it.
      #
      # Distinct from `add_behaviour_implementor_anchors/3` which anchors
      # the IMPLEMENTOR side. This anchors the DEFINITION side.
      behaviour =
        parse(
          """
          defmodule MyLib.Client do
            @moduledoc false
            @callback init(any) :: {:ok, map()} | {:error, any}
            @callback close(map()) :: :ok
          end
          """,
          "lib/mylib/client.ex"
        )

      implementor =
        parse(
          """
          defmodule MyLib.AmqpClient do
            @moduledoc "Public adapter."
            @behaviour MyLib.Client
            def init(opts), do: {:ok, %{opts: opts}}
            def close(_state), do: :ok
          end
          """,
          "lib/mylib/amqp_client.ex"
        )

      diags =
        UnanchoredModule.analyze_project([behaviour, implementor], library?: true)

      flagged = Enum.map(diags, & &1.context.module)

      refute "MyLib.Client" in flagged,
             "behaviour-DEFINITION referenced by @behaviour Mod from an anchored module must be anchored"
    end

    test "library mode is opt-in — without library?: true, public modules can flag" do
      # Sanity: library mode is gated on the opts flag. With it
      # absent (or false), CE-30 behaves as before.
      public =
        parse(
          """
          defmodule MyLib do
            def parse(input), do: input
          end
          """,
          "lib/mylib.ex"
        )

      diags = UnanchoredModule.analyze_project([public])
      assert ["MyLib"] = Enum.map(diags, & &1.context.module)
    end

    test "fixes include a 'run with --compiled and cross-check' option" do
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
          defmodule MyApp.Maybe do
            def hi, do: :hi
          end
          """,
          "lib/my_app/maybe.ex"
        )
      ]

      [diag] = UnanchoredModule.analyze_project(file_asts)

      summaries = Enum.map(diag.alternatives, & &1.summary)
      details = Enum.map(diag.alternatives, & &1.detail)

      assert Enum.any?(summaries, &String.contains?(&1, "compiled")) or
               Enum.any?(details, &String.contains?(&1, "compiled"))
    end
  end
end
