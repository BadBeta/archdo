defmodule Archdo.Rules.Testing.TestMirrorsSource do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "7.1"

  @impl true
  def description, do: "Test file structure should mirror source structure"

  @doc """
  Project-level analysis. Takes lists of source and test files.
  """
  def analyze_project(source_files, test_files) do
    test_set = MapSet.new(test_files, &normalize_test_path/1)

    for file <- source_files,
        not skip?(file),
        not MapSet.member?(test_set, expected_test_path(file)) do
      expected = "test/#{expected_test_path(file)}_test.exs"

      Diagnostic.info("7.1",
        title: "Source file with no matching test file",
        message: "#{AST.relative_path(file)} has no corresponding test file at #{expected}",
        why:
          "The convention `lib/foo/bar.ex` ↔ `test/foo/bar_test.exs` makes the test layout predictable: any " <>
            "developer can guess where to find the tests for a module without searching. When source files " <>
            "lack mirrored tests, the missing files are invisible to coverage tools, hard to find for new " <>
            "contributors, and gradually the test suite stops covering whole sub-trees of the codebase.",
        alternatives: [
          Fix.new(
            summary: "Add a test file at the mirrored path",
            detail:
              "Create `#{expected}` and add at least one test for the public functions in the source module. " <>
                "The mirroring rule no longer fires and you've documented the module's behaviour with examples.",
            applies_when: "The module has public functions worth testing."
          ),
          Fix.new(
            summary: "Make the module `@moduledoc false` if it doesn't need its own tests",
            detail:
              "Some modules (small structs, generated files, infrastructure glue) don't warrant a dedicated " <>
                "test file because they're tested transitively through their callers. Mark them `@moduledoc false` " <>
                "and the rule sees them as internal.",
            applies_when: "The module is internal infrastructure tested via its callers."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#7.1"],
        context: %{source: AST.relative_path(file), expected_test: expected},
        file: file,
        line: 0
      )
    end
  end

  defp expected_test_path(source_file) do
    source_file
    |> String.replace_prefix("lib/", "")
    |> String.trim_trailing(".ex")
  end

  defp normalize_test_path(test_file) do
    test_file
    |> String.replace_prefix("test/", "")
    |> String.trim_trailing("_test.exs")
  end

  defp skip?(file) do
    # Skip application.ex, mix tasks, and other non-domain files
    String.ends_with?(file, "/application.ex") or
      String.contains?(file, "/mix/") or
      String.ends_with?(file, "_web.ex") or
      String.ends_with?(file, "/endpoint.ex") or
      String.ends_with?(file, "/router.ex") or
      String.ends_with?(file, "/telemetry.ex") or
      String.ends_with?(file, "/repo.ex") or
      String.ends_with?(file, "/mailer.ex")
  end
end
