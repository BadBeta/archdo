defmodule Archdo.Rules.Testing.UntestedModule do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — operational layer carve-out via Archdo.Phoenix.
  # Mix tasks, release scripts, and seeds aren't unit-tested in isolation;
  # they're integration boundaries.

  alias Archdo.{AST, Diagnostic, Fix, Phoenix}

  @impl true
  def id, do: "7.25"

  @impl true
  def description, do: "Source module has no corresponding test file"

  @impl true
  def analyze(file, ast, opts) do
    classification =
      case Keyword.get(opts, :phoenix) do
        %{layer: _} = c -> c
        _ -> Phoenix.classify_file(file, ast)
      end

    case AST.test_file?(file) do
      true -> []
      false -> check_for_test_file(file, ast, classification)
    end
  end

  defp check_for_test_file(file, ast, classification) do
    cond do
      skip_file?(file, ast, classification) -> []
      test_file_exists?(file) -> []
      true -> [untested_diagnostic(file, ast)]
    end
  end

  defp skip_file?(file, ast, classification) do
    AST.internal_module?(ast) or
      migration_file?(file) or
      generated_file?(file) or
      config_file?(file) or
      Phoenix.operational?(classification)
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
    project_root = AST.find_mix_root(file)
    test_paths = AST.test_paths_from_mix(project_root)
    candidates = candidate_test_paths(file, test_paths, project_root)

    Enum.any?(candidates, &File.exists?/1)
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

  @doc """
  Build candidate test file paths for `file` given the project's test_paths
  list. Generates one nested candidate (mirrors lib/ structure under each
  test_path) and one flat candidate (basename only) per test_path. Optional
  `project_root` rebases the candidates so on-disk lookup works for absolute
  source paths.
  """
  @spec candidate_test_paths(String.t(), [String.t()], String.t() | nil) :: [String.t()]
  def candidate_test_paths(file, test_paths, project_root \\ nil) do
    rel_under_lib =
      case Path.split(rel_to_root(file, project_root)) do
        ["lib" | rest] -> Path.join(rest)
        other -> Path.join(other)
      end

    basename_test = Path.basename(file, ".ex") <> "_test.exs"
    rel_test = String.replace_suffix(rel_under_lib, ".ex", "_test.exs")

    Enum.flat_map(test_paths, fn tp ->
      [
        join_under_root(project_root, Path.join(tp, rel_test)),
        join_under_root(project_root, Path.join(tp, basename_test))
      ]
    end)
    |> Enum.uniq()
  end

  defp rel_to_root(file, nil), do: file
  defp rel_to_root(file, root), do: Path.relative_to(file, root)

  defp join_under_root(nil, p), do: p
  defp join_under_root(root, p), do: Path.join(root, p)

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
