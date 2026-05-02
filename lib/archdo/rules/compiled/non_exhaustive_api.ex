defmodule Archdo.Rules.Compiled.NonExhaustiveApi do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Compiled.Graph
  alias Archdo.Rules.Compiled.Helpers

  @impl true
  def id, do: "6.27"

  @impl true
  def description, do: "Public API function has no catch-all clause — crashes on unexpected input"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  # Minimum clauses to consider — single-clause functions don't need a catch-all
  @min_clauses 2

  @spec analyze_compiled(Graph.t()) :: [Diagnostic.t()]
  def analyze_compiled(%Graph{beam_dir: beam_dir}) when is_binary(beam_dir) do
    beam_dir
    |> Graph.extract_function_clauses()
    |> Enum.flat_map(fn {module, functions} ->
      functions
      |> Enum.filter(fn fn_info ->
        fn_info.exported and
          fn_info.clause_count >= @min_clauses and
          not fn_info.has_catch_all and
          not Helpers.framework_function?(fn_info.name) and
          not Helpers.generated_function?(fn_info.name)
      end)
      |> Enum.map(fn fn_info ->
        build_diagnostic(module, fn_info)
      end)
    end)
  end

  def analyze_compiled(_graph), do: []

  defp build_diagnostic(module, fn_info) do
    mod_name = AST.module_name(module)

    pattern_summary =
      Enum.map_join(fn_info.clauses, " | ", fn clause ->
        summarize_patterns(clause.patterns)
      end)

    Diagnostic.info("6.27",
      title: "Non-exhaustive public API",
      message:
        "#{mod_name}.#{fn_info.name}/#{fn_info.arity} has #{fn_info.clause_count} " <>
          "clauses but no catch-all — unexpected input causes FunctionClauseError",
      why:
        "This public function pattern-matches on specific shapes " <>
          "(#{pattern_summary}) but has no fallback clause. If called with an input " <>
          "that doesn't match any clause, it raises FunctionClauseError. For internal " <>
          "dispatch this is fine (let it crash), but public API functions should either " <>
          "handle all inputs or document their constraints clearly.",
      alternatives: [
        Fix.new(
          summary: "Add a catch-all clause returning {:error, :invalid_input}",
          detail:
            "Add a final clause: `def #{fn_info.name}(#{catch_all_args(fn_info.arity)}), " <>
              "do: {:error, :invalid_input}` — callers can then handle the error gracefully.",
          applies_when: "The function is part of a public API that may receive varied input."
        ),
        Fix.new(
          summary: "Add guards to document constraints",
          detail:
            "If the function intentionally only accepts specific shapes, add " <>
              "@spec and guard clauses to make the contract explicit.",
          applies_when: "The restricted input set is by design."
        ),
        Fix.new(
          summary: "Accept the crash if this is internal dispatch",
          detail:
            "If this function is only called from within the module with controlled " <>
              "input, the crash-on-unexpected-input is correct Elixir style.",
          applies_when: "The function is public for technical reasons but not truly API."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.27"],
      context: %{
        module: mod_name,
        function: "#{fn_info.name}/#{fn_info.arity}",
        clause_count: fn_info.clause_count,
        patterns: pattern_summary
      },
      file: "lib",
      line: 0
    )
  end

  defp summarize_patterns(args) do
    Enum.map_join(args, ", ", &summarize_pattern/1)
  end

  defp summarize_pattern({:atom, _, value}), do: ":#{value}"
  defp summarize_pattern({:tuple, _, elements}), do: "{#{length(elements)}-tuple}"
  defp summarize_pattern({:map, _, fields}), do: "%{#{length(fields)} fields}"
  defp summarize_pattern({:cons, _, _, _}), do: "[_|_]"
  defp summarize_pattern({nil, _}), do: "[]"
  defp summarize_pattern({:var, _, _}), do: "_"
  defp summarize_pattern({:match, _, _lhs, rhs}), do: summarize_pattern(rhs)
  defp summarize_pattern({:bin, _, _}), do: "<<>>"
  defp summarize_pattern({:integer, _, n}), do: "#{n}"
  defp summarize_pattern(_), do: "?"

  defp catch_all_args(arity) do
    Enum.map_join(1..arity, ", ", fn _ -> "_" end)
  end
end
