defmodule Archdo.Rules.Module.KeywordLookupInLoop do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Rules.Helpers.LoopDetection

  @impl true
  def id, do: "6.53"

  @impl true
  def description, do: "Keyword.get/fetch inside a loop — Keyword lists are O(n) for lookups"

  @keyword_lookup_fns [:get, :fetch, :fetch!, :has_key?, :get_lazy]

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_keyword_in_loops(file, ast)
    end
  end

  defp find_keyword_in_loops(file, ast) do
    predicate = fn
      {{:., _, [{:__aliases__, _, [:Keyword]}, func]}, _, _}
      when func in @keyword_lookup_fns ->
        true

      _ ->
        false
    end

    LoopDetection.find_in_all_loops(ast, predicate)
    |> Enum.map(fn {_, meta} -> build_diagnostic(file, AST.line(meta)) end)
  end

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.53",
      title: "Keyword lookup inside loop",
      message: "Keyword.get/fetch inside a loop is O(n) per lookup — convert to Map first",
      why:
        "Keyword lists are stored as a list of {key, value} tuples. " <>
          "Keyword.get scans linearly to find the key. Inside a loop of m iterations " <>
          "with a keyword list of n entries, this is O(m*n). " <>
          "Converting to a Map once (O(n)) then using Map.get (O(log n)) is faster.",
      alternatives: [
        Fix.new(
          summary: "Convert to Map before the loop",
          detail:
            "`map = Map.new(keyword_list)` before the loop,\n" <>
              "then `Map.get(map, key)` inside the loop.",
          applies_when: "The keyword list doesn't change during the loop."
        )
      ],
      tags: [:perf],
      file: file,
      line: line
    )
  end
end
