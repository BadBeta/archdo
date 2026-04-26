defmodule Archdo.Rules.Module.StringLengthCheck do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.52"

  @impl true
  def description, do: "String.length/1 used for empty/size check — use byte_size/1 or == \"\""

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_string_length_checks(file, ast)
    end
  end

  defp find_string_length_checks(file, ast) do
    Enum.map(
      AST.find_all(ast, fn
        # String.length(s) == 0
        {:==, _, [{{:., _, [{:__aliases__, _, [:String]}, :length]}, _, _}, val]} ->
          zero_literal?(val)

        # String.length(s) > 0
        {:>, _, [{{:., _, [{:__aliases__, _, [:String]}, :length]}, _, _}, val]} ->
          zero_literal?(val)

        # String.length(s) != 0
        {:!=, _, [{{:., _, [{:__aliases__, _, [:String]}, :length]}, _, _}, val]} ->
          zero_literal?(val)

        # 0 == String.length(s)
        {:==, _, [val, {{:., _, [{:__aliases__, _, [:String]}, :length]}, _, _}]} ->
          zero_literal?(val)

        _ ->
          false
      end),
      fn {op, meta, _} ->
        kind =
          case op do
            :== -> :empty_check
            :!= -> :non_empty_check
            :> -> :non_empty_check
          end

        build_diagnostic(file, AST.line(meta), kind)
      end
    )
  end

  defp zero_literal?(0), do: true
  defp zero_literal?({:__block__, _, [0]}), do: true
  defp zero_literal?(_), do: false

  defp build_diagnostic(file, line, :empty_check) do
    Diagnostic.info("6.52",
      title: "String.length for empty check",
      message:
        "`String.length(s) == 0` traverses entire string — use `s == \"\"` or `byte_size(s) == 0`",
      why:
        "String.length/1 counts Unicode graphemes by traversing the entire string, O(n). " <>
          "Checking `s == \"\"` is O(1) (empty binary check). " <>
          "`byte_size(s) == 0` is also O(1) and works in guards.",
      alternatives: [
        Fix.new(
          summary: "Use `s == \"\"` or `byte_size(s) == 0`",
          detail:
            "`String.length(s) == 0` -> `s == \"\"`\n" <>
              "In guards: `when byte_size(s) == 0`",
          applies_when: "Checking if a string is empty."
        )
      ],
      tags: [:perf],
      file: file,
      line: line
    )
  end

  defp build_diagnostic(file, line, :non_empty_check) do
    Diagnostic.info("6.52",
      title: "String.length for non-empty check",
      message:
        "`String.length(s) > 0` traverses entire string — use `s != \"\"` or `byte_size(s) > 0`",
      why:
        "String.length/1 counts Unicode graphemes by traversing the entire string, O(n). " <>
          "Checking `s != \"\"` is O(1). `byte_size(s) > 0` is also O(1) and works in guards.",
      alternatives: [
        Fix.new(
          summary: "Use `s != \"\"` or `byte_size(s) > 0`",
          detail:
            "`String.length(s) > 0` -> `s != \"\"`\n" <>
              "In guards: `when byte_size(s) > 0`",
          applies_when: "Checking if a string is non-empty."
        )
      ],
      tags: [:perf],
      file: file,
      line: line
    )
  end
end
