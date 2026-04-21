defmodule Archdo.Rules.Testing.MissingErrorPath do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @min_test_count 5

  @impl true
  def id, do: "7.22"

  @impl true
  def description, do: "Test module with many tests but no error-path coverage"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      false -> []
      true -> check_error_path_coverage(file, ast)
    end
  end

  defp check_error_path_coverage(file, ast) do
    test_blocks = extract_test_blocks(ast)
    total = length(test_blocks)

    case total >= @min_test_count do
      false ->
        []

      true ->
        error_test_count =
          Enum.count(test_blocks, fn {_name, _meta, body} -> has_error_pattern?(body) end)

        case error_test_count do
          0 -> [missing_error_path_diagnostic(file, ast, total)]
          _ -> []
        end
    end
  end

  defp extract_test_blocks(ast) do
    ast
    |> AST.find_all(fn
      {:test, _meta, [_name | _]} -> true
      _ -> false
    end)
    |> Enum.map(fn {:test, meta, [name | rest]} ->
      body =
        case rest do
          [_, [do: body]] -> body
          [[do: body]] -> body
          _ -> nil
        end

      {name, meta, body}
    end)
  end

  defp has_error_pattern?(nil), do: false

  defp has_error_pattern?(body) do
    AST.contains?(body, fn
      # {:error, _} tuple literal
      {:{}, _, [:error | _]} -> true
      {:error, _} -> true
      # assert_raise / assert_error
      {:assert_raise, _, _} -> true
      {:assert_error, _, _} -> true
      # catch_error
      {:catch_error, _, _} -> true
      _ -> false
    end)
  end

  defp missing_error_path_diagnostic(file, ast, total) do
    module_name = AST.extract_module_name(ast)

    Diagnostic.info("7.22",
      title: "No error-path tests",
      message:
        "#{module_name} has #{total} tests but none exercise error or failure paths",
      why:
        "Happy-path-only test suites give a false sense of coverage. Production code encounters " <>
          "invalid input, network failures, and race conditions. Without error-path tests, these " <>
          "scenarios are only discovered in production — the most expensive place to find bugs.",
      alternatives: [
        Fix.new(
          summary: "Add tests for {:error, _} return values",
          detail:
            "Identify public functions that return {:error, reason} tuples and write tests " <>
              "that trigger those paths with invalid or edge-case inputs.",
          applies_when: "The module under test uses ok/error tuples."
        ),
        Fix.new(
          summary: "Add tests using assert_raise for expected exceptions",
          detail:
            "If the module raises on invalid input, write tests with assert_raise/2 to verify " <>
              "the correct exception type and message.",
          applies_when: "The module uses bang functions that raise."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#7.22"],
      context: %{test_count: total},
      file: file,
      line: 1
    )
  end
end
