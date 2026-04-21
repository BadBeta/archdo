defmodule Archdo.Rules.Module.ReinventedEnumerable do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "3.5"

  @impl true
  def description, do: "Reinventing iteration patterns instead of using Enum/Stream"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      find_manual_iteration(file, ast)
    end
  end

  # Heuristic: look for functions that take an index parameter and recurse.
  # The classic anti-pattern is:
  #
  #   def walk(list, n, acc \\ [])
  #   def walk(_list, -1, acc), do: acc
  #   def walk(list, n, acc), do: walk(list, n - 1, [Enum.at(list, n) | acc])
  #
  # This is reinventing Enum.reverse or Enum.take. We detect:
  # 1. Enum.at/2 called in a recursive function
  # 2. Multi-clause recursive functions with an integer index accumulator
  defp find_manual_iteration(file, ast) do
    fns = AST.extract_functions(ast, :all)

    Enum.flat_map(fns, fn {name, arity, meta, _args, body} ->
      check_function(file, name, arity, meta, body)
    end)
  end

  defp check_function(_file, _name, _arity, _meta, nil), do: []

  defp check_function(file, name, arity, meta, body) do
    # The classic smell: Enum.at/2 inside a function body (suggests positional access)
    uses_enum_at? =
      AST.contains?(body, fn
        {{:., _, [{:__aliases__, _, [:Enum]}, :at]}, _, _} -> true
        _ -> false
      end)

    # And calls itself recursively (function name appears in body)
    is_recursive? =
      AST.contains?(body, fn
        {^name, _, args} when is_list(args) and length(args) == arity -> true
        _ -> false
      end)

    if uses_enum_at? and is_recursive? do
      [
        Diagnostic.info("3.5",
          title: "Manual recursion with Enum.at",
          message: "#{name}/#{arity} is recursive and uses Enum.at/2",
          why:
            "Enum.at/2 is O(n) for lists. A recursive function that calls Enum.at on each iteration becomes " <>
              "O(n²) — fine for tiny lists but a quadratic surprise on real data. The pattern also reinvents " <>
              "iteration primitives that Elixir already provides via Enum.reduce, Enum.with_index, and Stream, " <>
              "which are clearer at the call site and have better complexity.",
          alternatives: [
            Fix.new(
              summary: "Use `Enum.reduce/3` or `Enum.with_index/1`",
              detail:
                "Replace the manual index-tracking with one of Enum's iteration helpers. Enum.with_index gives " <>
                  "you `(item, index)` pairs without lookups; Enum.reduce gives you sequential accumulation. " <>
                  "Both are O(n).",
              example: """
              ```elixir
              list
              |> Enum.with_index()
              |> Enum.map(fn {item, idx} -> process(item, idx) end)
              ```
              """,
              applies_when: "The recursion is iterating over a known list."
            ),
            Fix.new(
              summary: "Switch to a Stream pipeline",
              detail:
                "If the data is large or comes from an external source, use Stream functions to process it " <>
                  "lazily. Memory usage stays bounded and the code reads top-to-bottom rather than as a recursion.",
              applies_when: "The data is large or streamed."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#3.5"],
          context: %{function: "#{name}/#{arity}"},
          file: file,
          line: AST.line(meta)
        )
      ]
    else
      []
    end
  end
end
