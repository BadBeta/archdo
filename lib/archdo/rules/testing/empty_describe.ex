defmodule Archdo.Rules.Testing.EmptyDescribe do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "7.24"

  @impl true
  def description, do: "Empty describe block — contains no test cases"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      false -> []
      true -> find_empty_describes(file, ast)
    end
  end

  defp find_empty_describes(file, ast) do
    ast
    |> AST.find_all(fn
      {:describe, _meta, [_name | _]} -> true
      _ -> false
    end)
    |> Enum.flat_map(fn {:describe, meta, [name | rest]} ->
      body = extract_body(rest)

      case has_tests?(body) do
        true -> []
        false -> [empty_describe_diagnostic(file, meta, name)]
      end
    end)
  end

  defp extract_body([[do: body]]), do: body
  defp extract_body([_, [do: body]]), do: body
  defp extract_body(_), do: nil

  defp has_tests?(nil), do: false

  defp has_tests?(body) do
    AST.contains?(body, fn
      {:test, _, [_ | _]} -> true
      _ -> false
    end)
  end

  defp unwrap_string({:__block__, _, [s]}) when is_binary(s), do: s
  defp unwrap_string(s) when is_binary(s), do: s
  defp unwrap_string(other), do: Macro.to_string(other)

  defp empty_describe_diagnostic(file, meta, name) do
    name_str = unwrap_string(name)

    Diagnostic.info("7.24",
      title: "Empty describe block",
      message: "describe \"#{name_str}\" contains no test cases",
      why:
        "An empty describe block is dead scaffolding. It adds visual noise to the test file " <>
          "without contributing any coverage. It often signals that someone intended to write tests " <>
          "but never followed through, leaving a blind spot in the test suite.",
      alternatives: [
        Fix.new(
          summary: "Add tests for the described functionality",
          detail:
            "Fill the describe block with test cases that exercise the function or scenario named " <>
              "in the description string.",
          applies_when: "The described functionality exists and needs testing."
        ),
        Fix.new(
          summary: "Remove the empty describe block",
          detail:
            "If the described functionality no longer exists or is tested elsewhere, " <>
              "delete the empty block to reduce noise.",
          applies_when: "The describe block is leftover scaffolding."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#7.24"],
      context: %{describe_name: name_str},
      file: file,
      line: AST.line(meta)
    )
  end
end
