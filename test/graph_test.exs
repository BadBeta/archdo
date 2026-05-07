defmodule Archdo.GraphTest do
  use ExUnit.Case, async: true

  alias Archdo.Graph

  describe "edge_of_type?/2" do
    test "true when edge.type matches the given kind" do
      edge = %{source: "A", target: "B", type: :call, file: "a.ex", line: 1}
      assert Graph.edge_of_type?(edge, :call)
    end

    test "false when edge.type doesn't match" do
      edge = %{source: "A", target: "B", type: :call, file: "a.ex", line: 1}
      refute Graph.edge_of_type?(edge, :alias)
    end

    test "matches across all known dep types" do
      for type <- [:call, :alias, :import, :use, :registry] do
        edge = %{source: "A", target: "B", type: type, file: "a.ex", line: 1}
        assert Graph.edge_of_type?(edge, type)
      end
    end
  end

  describe "alias-table resolution at call sites — multi-component references" do
    # `alias Changelog.{Files}` makes `Files` a short alias for
    # `Changelog.Files`. When source code then uses `Files.Image.foo()`,
    # the call edge should target `Changelog.Files.Image` — NOT
    # `Files.Image`. The graph builder's `resolve_alias/2` correctly
    # handles single-component shorts (`Files.foo()` → `Changelog.Files`)
    # but the multi-component clause `[atom, atom, ...]` skipped the
    # alias_table entirely, so every short-alias multi-component call
    # produced a dangling edge to a partial name. Symptom: CE-30 etc.
    # see the called module as orphan because the closure walk follows
    # the wrong target.

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

    test "multi-segment short-alias `Files.Image.foo()` resolves to fully-qualified target" do
      # `alias Changelog.Files; Files.Image.foo()` — target should be
      # `Changelog.Files.Image`, not `Files.Image`.
      code = ~S"""
      defmodule Changelog.Worker do
        alias Changelog.Files

        def go, do: Files.Image.versions()
      end
      """

      graph = Graph.build([parse(code, "lib/changelog/worker.ex")])
      deps = Graph.dependencies(graph, "Changelog.Worker")
      targets = deps |> Enum.map(& &1.target) |> Enum.uniq() |> Enum.sort()

      assert "Changelog.Files.Image" in targets,
             "alias-table must resolve the FIRST component of a multi-segment reference; got: #{inspect(targets)}"
    end

    test "multi-form alias `Changelog.{Files}` resolves nested calls" do
      code = ~S"""
      defmodule Changelog.Worker do
        alias Changelog.{Files, Episode}

        def go(id) do
          Episode.fetch(id)
          Files.Image.versions()
        end
      end
      """

      graph = Graph.build([parse(code, "lib/changelog/worker.ex")])
      deps = Graph.dependencies(graph, "Changelog.Worker")
      targets = deps |> Enum.map(& &1.target) |> Enum.uniq() |> MapSet.new()

      assert MapSet.member?(targets, "Changelog.Files.Image")
      assert MapSet.member?(targets, "Changelog.Episode")
    end

    test "fully-qualified call without alias is unchanged" do
      # No alias declaration; `Foo.Bar.baz()` resolves to `Foo.Bar`
      # directly via safe_concat.
      code = ~S"""
      defmodule MyApp.Worker do
        def go, do: MyApp.Helper.run()
      end
      """

      graph = Graph.build([parse(code, "lib/my_app/worker.ex")])
      deps = Graph.dependencies(graph, "MyApp.Worker")
      targets = deps |> Enum.map(& &1.target) |> Enum.uniq()

      assert "MyApp.Helper" in targets
    end
  end

  describe "plug-module references — Phoenix runtime dispatch" do
    # `plug Authorize, [Policies.Episode, :podcast]` is the Phoenix
    # plug-pipeline pattern — Authorize's `init/1` and `call/2` are
    # invoked by the Plug pipeline at runtime, AND Authorize's `init/1`
    # may itself reference modules from its options list (`Policies.Episode`)
    # to dispatch authorization at runtime via apply/3.
    #
    # Without recognising this shape, the AST graph captures zero edges
    # to the plug or its referenced modules. CE-30 then flags every
    # plug-only-referenced module (Authorize, Policies.Episode, etc.)
    # as orphan even though they're called every request.

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

    test "`plug Module` (1-arg) emits an edge to Module" do
      code = ~S"""
      defmodule MyAppWeb.Controller do
        plug MyApp.Authenticate
      end
      """

      graph = Graph.build([parse(code, "lib/my_app_web/controller.ex")])
      targets = Graph.dependencies(graph, "MyAppWeb.Controller") |> Enum.map(& &1.target)

      assert "MyApp.Authenticate" in targets
    end

    test "`plug Module, opts` emits an edge to Module" do
      code = ~S"""
      defmodule MyAppWeb.Controller do
        plug MyApp.Authorize, role: :admin
      end
      """

      graph = Graph.build([parse(code, "lib/my_app_web/controller.ex")])
      targets = Graph.dependencies(graph, "MyAppWeb.Controller") |> Enum.map(& &1.target)

      assert "MyApp.Authorize" in targets
    end

    test "`plug Authorize, [PolicyModule, :resource]` emits edges to BOTH the plug AND the policy" do
      # The plug's init/1 / call/2 receive the opts list including
      # PolicyModule, then dispatch to it via apply/3. PolicyModule
      # is therefore reachable through the plug-pipeline but invisible
      # to the AST call walker without this carve-out.
      code = ~S"""
      defmodule MyAppWeb.EpisodeController do
        plug MyApp.Authorize, [MyApp.Policies.Episode, :podcast]
      end
      """

      graph = Graph.build([parse(code, "lib/my_app_web/episode_controller.ex")])

      targets =
        Graph.dependencies(graph, "MyAppWeb.EpisodeController")
        |> Enum.map(& &1.target)
        |> Enum.uniq()

      assert "MyApp.Authorize" in targets
      assert "MyApp.Policies.Episode" in targets
    end

    test "`plug :atom_function` does NOT emit a module edge (it's a private fn)" do
      # `plug :authenticate` registers a private function on the
      # current module — already handled by dead_private_function's
      # plug recognition. No edge to a module needed here.
      code = ~S"""
      defmodule MyAppWeb.Controller do
        plug :authenticate
        defp authenticate(conn, _opts), do: conn
      end
      """

      graph = Graph.build([parse(code, "lib/my_app_web/controller.ex")])
      targets = Graph.dependencies(graph, "MyAppWeb.Controller") |> Enum.map(& &1.target)

      # No module edges from `plug :authenticate` itself.
      refute Enum.any?(targets, fn t -> String.starts_with?(t, "Authent") end)
    end
  end

  describe "suffix-resolution for macro-injected aliases" do
    # `use ChangelogWeb, :controller` (a project-defined helper)
    # expands to `quote do alias Changelog.Policies; ... end`. Archdo
    # cannot see the expansion. Then the controller has
    # `plug Authorize, [Policies.Admin.Episode, :podcast]`.
    # The `Policies` short-form is unresolvable to a full module name
    # via the file's alias_table (which has no `Policies` entry).
    # Result: edge target is "Policies.Admin.Episode" — a phantom
    # name that doesn't match any defined module.
    #
    # Heuristic: when ALL files have been parsed, post-process the
    # graph to resolve dangling short-name targets against the set of
    # defined modules. If exactly one defined module ends with
    # `<Phantom>` segments, substitute. If multiple modules suffix-
    # match (ambiguous), leave the dangling edge in place.

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

    test "dangling short-name target resolves to suffix-matching defined module" do
      controller =
        parse(
          """
          defmodule MyAppWeb.EpisodeController do
            plug Authorize, [Policies.Admin.Episode, :podcast]
          end
          """,
          "lib/my_app_web/controllers/episode_controller.ex"
        )

      policy =
        parse(
          """
          defmodule MyApp.Policies.Admin.Episode do
            def show(_actor, _resource), do: true
          end
          """,
          "lib/my_app/policies/admin/episode.ex"
        )

      graph = Graph.build([controller, policy])
      targets = Graph.dependencies(graph, "MyAppWeb.EpisodeController") |> Enum.map(& &1.target)

      assert "MyApp.Policies.Admin.Episode" in targets,
             "suffix resolution must promote `Policies.Admin.Episode` to the unique matching defined module"
    end

    test "ambiguous suffix match — multiple modules end with same segments — does NOT resolve (safe)" do
      controller =
        parse(
          """
          defmodule MyAppWeb.Controller do
            plug Authorize, [Policies.X, :res]
          end
          """,
          "lib/my_app_web/controller.ex"
        )

      a =
        parse(
          """
          defmodule MyApp.A.Policies.X do
            def go, do: :ok
          end
          """,
          "lib/my_app/a/policies/x.ex"
        )

      b =
        parse(
          """
          defmodule MyApp.B.Policies.X do
            def go, do: :ok
          end
          """,
          "lib/my_app/b/policies/x.ex"
        )

      graph = Graph.build([controller, a, b])
      targets = Graph.dependencies(graph, "MyAppWeb.Controller") |> Enum.map(& &1.target)

      # Ambiguous — neither full-form is anchored; the short form stays.
      refute "MyApp.A.Policies.X" in targets
      refute "MyApp.B.Policies.X" in targets
    end
  end
end
