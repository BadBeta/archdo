defmodule Archdo.Rules.Boundary.UnusedDependencyTest do
  use ExUnit.Case, async: true

  alias Archdo.AST
  alias Archdo.Rules.Boundary.UnusedDependency

  defp tmp_file(code) do
    path = Path.join(System.tmp_dir!(), "unused_dep_#{:rand.uniform(1_000_000)}.ex")
    File.write!(path, code)
    path
  end

  defp run(code) do
    path = tmp_file(code)

    try do
      {:ok, ast} = AST.parse_file(path)
      UnusedDependency.analyze(path, ast, [])
    after
      File.rm(path)
    end
  end

  test "flags an alias whose short name is never referenced" do
    code = ~S"""
    defmodule MyApp.M do
      alias MyApp.Helper

      def go, do: :ok
    end
    """

    diags = run(code)
    assert length(diags) == 1
    assert hd(diags).message =~ "Helper"
  end

  test "does NOT flag an alias whose short name IS referenced" do
    code = ~S"""
    defmodule MyApp.M do
      alias MyApp.Helper

      def go, do: Helper.run()
    end
    """

    assert run(code) == []
  end

  # FP: `alias NimbleCSV.RFC4180, as: CSV` — the rule looked at the
  # last segment of the alias path (`RFC4180`) instead of the as-name
  # (`CSV`). Code using `CSV.parse_string(...)` never references
  # `RFC4180`, so the rule flagged the alias as unused even though
  # the as-name IS used. Real-world: every NimbleCSV consumer.
  test "does NOT flag `alias Foo.Bar, as: Baz` when as-name `Baz` is referenced" do
    code = ~S"""
    defmodule MyApp.Parser do
      alias NimbleCSV.RFC4180, as: CSV

      def parse(s), do: CSV.parse_string(s)
    end
    """

    assert run(code) == [],
           "as-name `CSV` IS referenced; rule must track the as-name not the last segment"
  end

  test "STILL flags `alias Foo.Bar, as: Baz` when neither name is referenced" do
    # Choose a Baz that is NOT a substring of the full path's segments —
    # the `unused_alias?` heuristic uses substring split, so "CSV" inside
    # "NimbleCSV" would wrongly count as a use. Separate FP class; out of
    # scope for the as: fix. This test guards the as-name detection.
    code = ~S"""
    defmodule MyApp.Parser do
      alias MyApp.SomeHelper, as: Bzz

      def go, do: :ok
    end
    """

    diags = run(code)
    assert length(diags) == 1
  end

  # FP: substring-match heuristic. `String.split(source, "Helper")`
  # counts `MyHelper` and `OtherHelper` as uses of `Helper`, so the
  # rule under-flagged when the short name was a substring of any
  # other identifier in the file. The fix uses word-boundary regex.
  test "does NOT under-flag when short-name is a substring of another identifier" do
    code = ~S"""
    defmodule MyApp.M do
      alias MyApp.Csv

      defmodule MyAppCsvParser do
        def go, do: :ok
      end
    end
    """

    # `Csv` aliased but only appears in the alias line and as substring
    # of `MyAppCsvParser` (which is NOT a use of the aliased `Csv`).
    # The rule MUST flag the alias as unused.
    diags = run(code)
    assert length(diags) == 1
  end
end
