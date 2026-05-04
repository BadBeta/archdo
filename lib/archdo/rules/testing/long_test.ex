defmodule Archdo.Rules.Testing.LongTest do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  # Recalibrated 2026-04-29: ast_size/1 no longer counts token metadata
  # (BUG-6 fix in archdo/ast.ex). Old threshold 1200 was metadata-inflated.
  @max_test_nodes 250

  @impl true
  def id, do: "7.12"

  @impl true
  def description, do: "Very large test bodies — likely testing too many things at once"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      false -> []
      true -> find_long_tests(file, ast)
    end
  end

  defp find_long_tests(file, ast) do
    AST.find_all(ast, fn
      {:test, _, args} when is_list(args) and length(args) >= 2 -> true
      _ -> false
    end)
    |> Enum.map(fn {:test, meta, args} ->
      body = List.last(args)
      size = AST.ast_size(body)
      name = AST.extract_test_name(args)

      if size > @max_test_nodes do
        Diagnostic.info("7.12",
          title: "Test body too long",
          message: "test #{inspect(name)} has #{size} AST nodes (limit: #{@max_test_nodes})",
          why:
            "Long test bodies usually verify several distinct behaviours interleaved. When one assertion " <>
              "fails, you don't know which behaviour broke without reading the whole test, and a partial " <>
              "regression can mask later assertions because the test bails on the first failure. Splitting into " <>
              "smaller named tests gives clearer failures and better documentation.",
          alternatives: [
            Fix.new(
              summary: "Split into focused tests, one behaviour per test",
              detail:
                "Use the Arrange-Act-Assert pattern: each test should arrange one specific scenario, perform " <>
                  "one operation, and assert on the result. The test name becomes the documentation for what's " <>
                  "being verified.",
              applies_when: "The test verifies multiple distinct behaviours."
            ),
            Fix.new(
              summary: "Extract repetitive arrange/assert helpers",
              detail:
                "If the test is long because of setup or assertion boilerplate, extract those into private " <>
                  "helpers or a fixtures module. The remaining test body shrinks to the actual scenario.",
              applies_when: "The bulk is repetitive setup or assertion code."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#7.12"],
          context: %{test_name: name, size: size, threshold: @max_test_nodes},
          file: file,
          line: AST.line(meta)
        )
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

end
