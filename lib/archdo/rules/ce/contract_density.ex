defmodule Archdo.Rules.CE.ContractDensity do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-11. A module representing an
  # irreversible decision (Ecto schema, supervisor, public-API path)
  # whose contract density is dramatically below the codebase median
  # on at least one sub-score: spec coverage on public functions OR
  # doc coverage on public functions.
  #
  # v1 sub-scores: spec_coverage, doc_coverage. Test density (test
  # LOC per source LOC) is deferred — needs paired source/test files
  # which the project-level analysis doesn't currently match up.
  #
  # Fires only when at least 3 candidate modules exist (cohort), and
  # only on candidates whose sub-score is < 50% of the cohort median.

  alias Archdo.{AST, Diagnostic, Fix, IrreversibleDecision}

  @median_floor 0.5
  @min_cohort_size 3

  @impl true
  def id, do: "CE-11"

  @impl true
  def description,
    do: "Irreversible-decision module (schema/supervisor/public API) lacks contract density"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc "Project-level. Returns one Diagnostic per under-density candidate."
  @spec analyze_project([{String.t(), Macro.t()}], keyword()) :: [Diagnostic.t()]
  def analyze_project(file_asts, opts \\ []) do
    candidates =
      file_asts
      |> Enum.reject(fn {file, _} -> AST.test_file?(file) end)
      |> Enum.filter(fn {file, ast} -> IrreversibleDecision.candidate?(file, ast, opts) end)
      |> Enum.reject(fn {_, ast} -> AST.has_marker?(ast, :archdo_skip_contract_check) end)
      |> Enum.map(fn {file, ast} -> {file, ast, sub_scores(ast)} end)
      |> Enum.reject(fn {_, _, scores} -> scores == nil end)

    case length(candidates) < @min_cohort_size do
      true ->
        []

      false ->
        spec_median = median(Enum.map(candidates, fn {_, _, s} -> s.spec_coverage end))
        doc_median = median(Enum.map(candidates, fn {_, _, s} -> s.doc_coverage end))

        Enum.flat_map(candidates, fn {file, ast, scores} ->
          fails = which_failed(scores, spec_median, doc_median)

          case fails do
            [] -> []
            list -> [build_diagnostic(file, ast, scores, list, spec_median, doc_median)]
          end
        end)
    end
  end

  defp sub_scores(ast) do
    publics = AST.extract_functions(ast, :public)

    case length(publics) do
      0 ->
        nil

      total ->
        spec_set = AST.spec_keys(ast)
        doc_set = collect_doc_keys(ast)

        with_specs = Enum.count(publics, fn {n, a, _, _, _} -> {n, a} in spec_set end)
        with_docs = Enum.count(publics, fn {n, a, _, _, _} -> {n, a} in doc_set end)

        %{
          spec_coverage: with_specs / total,
          doc_coverage: with_docs / total,
          public_count: total
        }
    end
  end

  # Walks the module body looking for `@doc ...` markers immediately
  # before `def name(args)` declarations, attributing the doc to that
  # function head.
  defp collect_doc_keys(ast) do
    body = AST.module_body(ast)

    {_set, _last_doc} =
      result =
        body
        |> Enum.reduce({MapSet.new(), false}, fn node, {acc, pending_doc?} ->
          cond do
            doc_attr?(node) ->
              {acc, true}

            def_node?(node) ->
              {n, a} = name_and_arity(node)

              case pending_doc? do
                true -> {MapSet.put(acc, {n, a}), false}
                false -> {acc, false}
              end

            true ->
              {acc, pending_doc?}
          end
        end)

    {set, _} = result
    set
  end

  defp doc_attr?({:@, _, [{:doc, _, [_]}]}), do: true
  defp doc_attr?({:@, _, [{:doc, _, _}]}), do: true
  defp doc_attr?(_), do: false

  defp def_node?({:def, _, [{name, _, args} | _]}) when is_atom(name) and (is_list(args) or args == nil), do: true
  defp def_node?({:def, _, [{:when, _, [{name, _, args} | _]} | _]}) when is_atom(name) and (is_list(args) or args == nil), do: true
  defp def_node?(_), do: false

  defp name_and_arity({:def, _, [{name, _, args} | _]}) when is_atom(name),
    do: {name, length(args || [])}

  defp name_and_arity({:def, _, [{:when, _, [{name, _, args} | _]} | _]}) when is_atom(name),
    do: {name, length(args || [])}

  defp median([]), do: 0.0

  defp median(scores) do
    sorted = Enum.sort(scores)
    n = length(sorted)
    middle = div(n, 2)

    case rem(n, 2) do
      1 -> Enum.at(sorted, middle)
      0 -> (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
    end
  end

  defp which_failed(scores, spec_median, doc_median) do
    spec_floor = spec_median * @median_floor
    doc_floor = doc_median * @median_floor

    []
    |> maybe_add(:spec_coverage, scores.spec_coverage, spec_floor, spec_median)
    |> maybe_add(:doc_coverage, scores.doc_coverage, doc_floor, doc_median)
  end

  defp maybe_add(list, key, value, floor, median) do
    # Only consider failure if the median is itself meaningful
    # (codebase has at least some contracts to compare against).
    case median > 0.0 and value < floor do
      true -> [{key, value, median} | list]
      false -> list
    end
  end

  defp build_diagnostic(file, ast, scores, fails, spec_median, doc_median) do
    module = AST.extract_module_name(ast)

    fails_summary =
      Enum.map_join(fails, "; ", fn {key, value, median} ->
        key_label = key |> Atom.to_string() |> String.replace("_", " ")

        "#{key_label} #{format_pct(value)} (median #{format_pct(median)})"
      end)

    Diagnostic.warning("CE-11",
      title: "Irreversible-decision module lacks contract density",
      message:
        "#{module}: irreversible decision (schema/supervisor/public API) is " <>
          "well below codebase median on contract density — #{fails_summary}",
      why:
        "Irreversible decisions are exactly where carelessness costs the most. " <>
          "A schema rolled out without specs becomes an unverifiable shape every " <>
          "consumer must guess at; a public API with no docs becomes everyone's " <>
          "reverse-engineering project. Comparing to the codebase median calibrates " <>
          "the threshold to the project's own standards.",
      alternatives: [
        Fix.new(
          summary: "Raise spec coverage to match cohort median",
          detail:
            "Add @spec to each public function. Even loose @specs (`@spec foo(map()) " <>
              ":: term()`) document entry shape and let Dialyzer trace from there.",
          applies_when: "spec_coverage is the failed sub-score."
        ),
        Fix.new(
          summary: "Raise doc coverage — add @moduledoc + @doc",
          detail:
            "Add @moduledoc to the module describing its purpose and @doc to each " <>
              "public function describing its contract. For Ecto schemas, document " <>
              "the table's role and any non-obvious fields.",
          applies_when: "doc_coverage is the failed sub-score."
        ),
        Fix.new(
          summary: "Mark @archdo_skip_contract_check with reason",
          detail:
            "If the module is internal-only despite looking irreversible (e.g., " <>
              "schemaless `embedded_schema` for in-process state), declare the " <>
              "intent: `@archdo_skip_contract_check \"internal-only embedded shape\"`.",
          applies_when: "The 'irreversible' classification is a false positive."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-11"],
      context: %{
        module: module,
        spec_coverage: scores.spec_coverage,
        doc_coverage: scores.doc_coverage,
        spec_median: spec_median,
        doc_median: doc_median,
        failed: Enum.map(fails, fn {k, _, _} -> k end)
      },
      file: file,
      line: 1
    )
  end

  defp format_pct(v) do
    pct = (v * 100) |> Float.round(0) |> trunc()
    "#{pct}%"
  end
end
