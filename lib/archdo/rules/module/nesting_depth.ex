defmodule Archdo.Rules.Module.NestingDepth do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @max_depth 4

  @impl true
  def id, do: "6.17"

  @impl true
  def description, do: "Deeply nested control flow — extract functions to flatten"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      find_deep_nesting(file, ast)
    end
  end

  defp find_deep_nesting(file, ast) do
    fns = AST.extract_functions(ast, :all)

    fns
    |> Enum.flat_map(fn {name, arity, meta, _args, body} ->
      max = max_nesting(body, 0)

      if max > @max_depth do
        [build_diagnostic(file, name, arity, meta, max)]
      else
        []
      end
    end)
  end

  defp max_nesting(nil, _depth), do: 0

  defp max_nesting({form, _, args}, depth) when form in [:case, :cond, :if, :with, :try] do
    child_max =
      args
      |> List.wrap()
      |> Enum.map(&max_nesting(&1, depth + 1))
      |> Enum.max(fn -> depth + 1 end)

    max(depth + 1, child_max)
  end

  defp max_nesting({_, _, args}, depth) when is_list(args) do
    args
    |> Enum.map(&max_nesting(&1, depth))
    |> Enum.max(fn -> depth end)
  end

  defp max_nesting({a, b}, depth) do
    max(max_nesting(a, depth), max_nesting(b, depth))
  end

  defp max_nesting(list, depth) when is_list(list) do
    list
    |> Enum.map(&max_nesting(&1, depth))
    |> Enum.max(fn -> depth end)
  end

  defp max_nesting(_, depth), do: depth

  defp build_diagnostic(file, name, arity, meta, depth) do
    Diagnostic.info("6.17",
      title: "Deep nesting",
      message: "#{name}/#{arity} has control flow nested #{depth} levels deep (max: #{@max_depth})",
      why:
        "Each nesting level (case inside with inside if) adds a branch the reader must " <>
          "track mentally. Beyond 3-4 levels, the code becomes hard to follow and test. " <>
          "Extract inner branches into named private functions — each becomes independently " <>
          "readable and testable.",
      alternatives: [
        Fix.new(
          summary: "Extract inner case/with blocks into private functions",
          detail:
            "Give the inner block a name that describes what it does. The outer function " <>
              "reads as a sequence of named steps instead of a nested maze.",
          applies_when: "The inner block has a clear purpose that can be named."
        ),
        Fix.new(
          summary: "Use `with` to flatten nested case statements",
          detail:
            "If the nesting is caused by chained `case` on ok/error, flatten with `with`.",
          applies_when: "The nesting is from chained ok/error matching."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.17"],
      context: %{function: "#{name}/#{arity}", depth: depth},
      file: file,
      line: AST.line(meta)
    )
  end
end
