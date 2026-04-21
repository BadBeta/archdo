defmodule Archdo.Rules.Testing.UntestedModule do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "7.25"

  @impl true
  def description, do: "Source module has no corresponding test file"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> check_for_test_file(file, ast)
    end
  end

  defp check_for_test_file(file, ast) do
    cond do
      skip_file?(file, ast) -> []
      test_file_exists?(file) -> []
      true -> [untested_diagnostic(file, ast)]
    end
  end

  defp skip_file?(file, ast) do
    AST.internal_module?(ast) or
      migration_file?(file) or
      generated_file?(file) or
      config_file?(file)
  end

  defp migration_file?(file), do: String.contains?(file, "/migrations/")
  defp generated_file?(file), do: String.contains?(file, "/generated/")

  defp config_file?(file) do
    basename = Path.basename(file)

    basename in [
      "application.ex",
      "repo.ex",
      "endpoint.ex",
      "router.ex",
      "telemetry.ex",
      "mailer.ex",
      "gettext.ex"
    ]
  end

  defp test_file_exists?(file) do
    file
    |> source_to_test_path()
    |> File.exists?()
  end

  @doc """
  Convert a source file path to its expected test file path.

  ## Examples

      iex> source_to_test_path("lib/my_app/accounts/user.ex")
      "test/my_app/accounts/user_test.exs"
  """
  @spec source_to_test_path(String.t()) :: String.t()
  def source_to_test_path(file) do
    file
    |> String.replace_prefix("lib/", "test/")
    |> String.replace_suffix(".ex", "_test.exs")
  end

  defp untested_diagnostic(file, ast) do
    module_name = AST.extract_module_name(ast)
    expected_test = source_to_test_path(file)

    Diagnostic.info("7.25",
      title: "Untested module",
      message: "#{module_name} has no test file (expected #{expected_test})",
      why:
        "A source module without a corresponding test file has zero automated verification. " <>
          "Even a minimal test that exercises the public API catches regressions early and " <>
          "documents expected behaviour for future maintainers.",
      alternatives: [
        Fix.new(
          summary: "Create a test file for the module",
          detail:
            "Create #{expected_test} with at least one test per public function. " <>
              "Focus on the module's contract — inputs, outputs, and side effects.",
          applies_when: "The module contains meaningful logic worth testing."
        ),
        Fix.new(
          summary: "Mark the module as internal if it needs no direct tests",
          detail:
            "If the module is purely structural (e.g., a protocol implementation tested " <>
              "through the protocol), add `@moduledoc false` to suppress this rule.",
          applies_when: "The module is tested indirectly through another module."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#7.25"],
      context: %{expected_test_file: expected_test},
      file: file,
      line: 1
    )
  end
end
