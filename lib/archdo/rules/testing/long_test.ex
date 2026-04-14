defmodule Archdo.Rules.Testing.LongTest do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @max_test_nodes 200

  @impl true
  def id, do: "7.12"

  @impl true
  def description, do: "Test bodies > 50 lines test too many things at once"

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
      size = ast_size(body)
      name = extract_test_name(args)

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

  defp ast_size(node), do: Archdo.AST.ast_size(node)

  defp extract_test_name([name | _]) when is_binary(name), do: name
  defp extract_test_name([{:__block__, _, [name]} | _]) when is_binary(name), do: name
  defp extract_test_name(_), do: "(unknown)"
end
