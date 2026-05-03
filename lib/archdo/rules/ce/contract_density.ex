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
  # M-Plan10: lowered from 3 → 2. Test-density gives meaningful
  # signal even for tiny cohorts because it's per-module, not
  # cross-module.
  @min_cohort_size 2

  @impl true
  def id, do: "CE-11"

  @impl true
  def description,
    do: "Irreversible-decision module (schema/supervisor/public API) lacks contract density"

  @doc "Project-level. Returns one Diagnostic per under-density candidate."
  @spec analyze_project([{String.t(), Macro.t()}], keyword()) :: [Diagnostic.t()]
  def analyze_project(file_asts, opts \\ []) do
    # §§ elixir-implementing: §10.5 — index test files once at the
    # entry, not per-candidate. Maps `lib/foo/bar.ex` →
    # `test/foo/bar_test.exs`.
    test_index = build_test_index(file_asts)

    candidates =
      file_asts
      |> Enum.reject(fn {file, _} -> AST.test_file?(file) end)
      |> Enum.filter(fn {file, ast} -> IrreversibleDecision.candidate?(file, ast, opts) end)
      |> Enum.reject(fn {_, ast} -> AST.has_marker?(ast, :archdo_skip_contract_check) end)
      |> Enum.map(fn {file, ast} -> {file, ast, sub_scores(ast, file, test_index)} end)
      |> Enum.reject(fn {_, _, scores} -> scores == nil end)

    case length(candidates) < @min_cohort_size do
      true ->
        []

      false ->
        spec_median = median(Enum.map(candidates, fn {_, _, s} -> s.spec_coverage end))
        doc_median = median(Enum.map(candidates, fn {_, _, s} -> s.doc_coverage end))
        test_median = median(Enum.map(candidates, fn {_, _, s} -> s.test_density end))
        medians = %{spec: spec_median, doc: doc_median, test: test_median}

        Enum.flat_map(candidates, &diag_for_candidate(&1, medians))
    end
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # the empty-list shape of `fails`.
  defp diag_for_candidate({file, ast, scores}, medians) do
    diag_if_failed(which_failed(scores, medians), file, ast, scores, medians)
  end

  defp diag_if_failed([], _file, _ast, _scores, _medians), do: []

  defp diag_if_failed(list, file, ast, scores, medians),
    do: [build_diagnostic(file, ast, scores, list, medians)]

  # §§ elixir-implementing: §2.6 — Map.new once for O(1) lookup.
  # Only test files (path ends with _test.exs) are indexed.
  defp build_test_index(file_asts) do
    file_asts
    |> Enum.filter(fn {file, _} -> AST.test_file?(file) end)
    |> Map.new()
  end

  # Pair `lib/foo/bar.ex` with `test/foo/bar_test.exs`. Returns the
  # test AST or nil. The convention is fixed: same relative path
  # under test/, file name with _test.exs suffix.
  defp paired_test_ast(source_file, test_index) do
    expected_test_path =
      source_file
      |> String.replace(~r{(^|/)lib/}, "\\1test/")
      |> String.replace(~r{\.ex$}, "_test.exs")

    Map.get(test_index, expected_test_path)
  end

  defp count_test_blocks(nil), do: 0

  defp count_test_blocks(test_ast) do
    # §§ elixir-implementing: §5.2 — multi-clause shape match.
    # `test "name" do ... end` parses as `{:test, _, args}` with a
    # variable arg count (2 with `do:` keyword, 3 with context arg
    # before `do:`). The `do:` keyword may be a bare `[do: body]`
    # OR a literal_encoder-wrapped `[{{:__block__, _, [:do]}, body}]`,
    # depending on how the source was parsed. Match both.
    {_, count} =
      Macro.prewalk(test_ast, 0, fn
        {:test, _, args} = node, acc when is_list(args) ->
          case test_block?(args) do
            true -> {node, acc + 1}
            false -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    count
  end

  defp test_block?(args) do
    Enum.any?(args, fn
      [{:do, _}] -> true
      [{:do, _} | _] -> true
      [{{:__block__, _, [:do]}, _} | _] -> true
      _ -> false
    end)
  end

  defp sub_scores(ast, source_file, test_index) do
    publics = AST.extract_functions(ast, :public)

    case length(publics) do
      0 ->
        nil

      total ->
        spec_set = AST.spec_keys(ast)
        doc_set = collect_doc_keys(ast)

        with_specs = Enum.count(publics, fn {n, a, _, _, _} -> {n, a} in spec_set end)
        with_docs = Enum.count(publics, fn {n, a, _, _, _} -> {n, a} in doc_set end)

        test_count = source_file |> paired_test_ast(test_index) |> count_test_blocks()

        %{
          spec_coverage: with_specs / total,
          doc_coverage: with_docs / total,
          test_density: min(1.0, test_count / total),
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
      Enum.reduce(body, {MapSet.new(), false}, &accumulate_documented_def/2)

    {set, _} = result
    set
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # node kind (doc attribute / def / other) via classifier helpers
  # plus the pending_doc? boolean.
  defp accumulate_documented_def(node, {acc, pending_doc?}) do
    classify_doc_walk_node(node_kind(node), node, acc, pending_doc?)
  end

  defp node_kind(node) do
    cond do
      doc_attr?(node) -> :doc_attr
      AST.def_node?(node) -> :def_node
      true -> :other
    end
  end

  defp classify_doc_walk_node(:doc_attr, _node, acc, _pending), do: {acc, true}

  defp classify_doc_walk_node(:def_node, node, acc, pending_doc?) do
    {n, a} = name_and_arity(node)
    record_def(pending_doc?, acc, n, a)
  end

  defp classify_doc_walk_node(:other, _node, acc, pending_doc?), do: {acc, pending_doc?}

  defp record_def(true, acc, n, a), do: {MapSet.put(acc, {n, a}), false}
  defp record_def(false, acc, _n, _a), do: {acc, false}

  defp doc_attr?({:@, _, [{:doc, _, [_]}]}), do: true
  defp doc_attr?({:@, _, [{:doc, _, _}]}), do: true
  defp doc_attr?(_), do: false

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

  defp which_failed(scores, %{spec: spec_median, doc: doc_median, test: test_median}) do
    spec_floor = spec_median * @median_floor
    doc_floor = doc_median * @median_floor
    test_floor = test_median * @median_floor

    []
    |> maybe_add(:spec_coverage, scores.spec_coverage, spec_floor, spec_median)
    |> maybe_add(:doc_coverage, scores.doc_coverage, doc_floor, doc_median)
    |> maybe_add(:test_density, scores.test_density, test_floor, test_median)
  end

  defp maybe_add(list, key, value, floor, median) do
    # Only consider failure if the median is itself meaningful
    # (codebase has at least some contracts to compare against).
    case median > 0.0 and value < floor do
      true -> [{key, value, median} | list]
      false -> list
    end
  end

  defp build_diagnostic(file, ast, scores, fails, medians) do
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
          "reverse-engineering project; an untested schema is one bad migration " <>
          "from a hidden invariant break. Comparing to the codebase median " <>
          "calibrates the threshold to the project's own standards.",
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
          summary: "Add a paired test file with one or more `test` blocks",
          detail:
            "Convention: a module at `lib/foo/bar.ex` is paired with a test file " <>
              "at `test/foo/bar_test.exs`. Even one `test \"...\"` block per public " <>
              "function lifts the test_density score above the cohort floor and " <>
              "guards the irreversible decision against silent regressions.",
          applies_when: "test_density is the failed sub-score."
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
        test_density: scores.test_density,
        spec_median: medians.spec,
        doc_median: medians.doc,
        test_median: medians.test,
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
