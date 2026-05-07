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
end
