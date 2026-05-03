defmodule Archdo.Rules.Testing.CoverageGap do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @warning_severity :warning

  # Callback functions and framework helpers that don't need direct test coverage
  @ignored_functions ~w(
    init child_spec start_link handle_call handle_cast handle_info handle_continue
    terminate code_change format_status
    mount render handle_event handle_params handle_async update
    changeset
    callback __using__ __before_compile__ __after_compile__
  )a

  @impl true
  def id, do: "7.14"

  @impl true
  def description, do: "Public API coverage gap — public functions not referenced in test file"

  @doc """
  Project-level: for each source file, find its test file and check which
  public functions are referenced.

  Returns a list of diagnostics for uncovered functions PLUS a summary
  diagnostic per module with the coverage ratio.
  """
  def analyze_project(file_asts) do
    # Partition into lib/ sources and test/ files
    {sources, tests} =
      Enum.split_with(file_asts, fn {file, _ast} -> not AST.test_file?(file) end)

    # Build a map: test_file_stem -> {file, ast} for quick lookup
    test_index = build_test_index(tests)

    Enum.flat_map(sources, fn {source_file, source_ast} ->
      check_source(source_file, source_ast, test_index)
    end)
  end

  @doc """
  Generate a project-wide matrix report for --coverage flag.
  Returns an iolist suitable for printing.
  """
  def matrix_report(file_asts) do
    {sources, tests} =
      Enum.split_with(file_asts, fn {file, _ast} -> not AST.test_file?(file) end)

    test_index = build_test_index(tests)

    rows =
      sources
      |> Enum.map(fn {source_file, source_ast} ->
        build_row(source_file, source_ast, test_index)
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(fn row -> {row.coverage_pct, row.module} end)

    format_matrix(rows)
  end

  # --- Per-source analysis ---

  defp check_source(source_file, source_ast, test_index) do
    check_source_for(ignore_source?(source_file, source_ast), source_file, source_ast, test_index)
  end

  # §§ elixir-implementing: §2.1 — boolean → multi-clause head dispatch
  # on the ignore predicate and on the empty publics shape.
  defp check_source_for(true, _source_file, _source_ast, _test_index), do: []

  defp check_source_for(false, source_file, source_ast, test_index),
    do: check_publics(collect_public_fns(source_ast), source_file, source_ast, test_index)

  defp check_publics([], _source_file, _source_ast, _test_index), do: []

  defp check_publics(public_fns, source_file, source_ast, test_index) do
    module_name = AST.extract_module_name(source_ast)
    {module_referenced?, test_refs} = analyze_test_file(source_file, module_name, test_index)

    uncovered =
      Enum.reject(public_fns, fn {name, arity} ->
        directly_referenced?(test_refs, name, arity)
      end)

    # If the module is referenced at all (via alias/use) but specific functions
    # aren't, that's still lower confidence coverage — report as an info
    # summary rather than per-function diagnostics.
    build_diagnostics(source_file, source_ast, public_fns, uncovered, module_referenced?)
  end

  defp build_row(source_file, source_ast, test_index) do
    build_row_for(ignore_source?(source_file, source_ast), source_file, source_ast, test_index)
  end

  defp build_row_for(true, _source_file, _source_ast, _test_index), do: nil

  defp build_row_for(false, source_file, source_ast, test_index),
    do: build_row_publics(collect_public_fns(source_ast), source_file, source_ast, test_index)

  defp build_row_publics([], _source_file, _source_ast, _test_index), do: nil

  defp build_row_publics(public_fns, source_file, source_ast, test_index) do
    module_name = AST.extract_module_name(source_ast)
    {module_referenced?, test_refs} = analyze_test_file(source_file, module_name, test_index)

    direct_covered =
      Enum.count(public_fns, fn {name, arity} ->
        directly_referenced?(test_refs, name, arity)
      end)

    total = length(public_fns)

    # If the module is referenced (aliased) but no specific functions, count
    # this as partial/indirect coverage (50% confidence).
    {covered, confidence} = coverage_verdict(direct_covered, total, module_referenced?)
    pct = coverage_pct(confidence, direct_covered, total)

    %{
      module: module_name,
      file: source_file,
      total: total,
      covered: covered,
      uncovered: total - covered,
      coverage_pct: pct,
      confidence: confidence,
      has_test: Map.has_key?(test_index, source_key(source_file))
    }
  end

  defp coverage_verdict(total, total, _ref?) when total > 0, do: {total, :full}
  defp coverage_verdict(direct, _total, _ref?) when direct > 0, do: {direct, :partial}
  defp coverage_verdict(_direct, _total, true), do: {0, :indirect}
  defp coverage_verdict(_direct, _total, _ref?), do: {0, :none}

  defp coverage_pct(:full, _direct, _total), do: 100
  defp coverage_pct(:partial, direct, total), do: round(direct * 100 / total)
  defp coverage_pct(:indirect, _direct, _total), do: 50
  defp coverage_pct(:none, _direct, _total), do: 0

  defp directly_referenced?(refs, name, arity) do
    {name, arity} in refs or {name, :any} in refs
  end

  defp analyze_test_file(source_file, module_name, test_index) do
    case Map.get(test_index, source_key(source_file)) do
      nil ->
        {false, []}

      test_ast ->
        module_parts =
          Enum.map(String.split(module_name, "."), fn part ->
            try do
              String.to_existing_atom(part)
            rescue
              ArgumentError -> part
            end
          end)

        module_referenced? =
          AST.contains?(test_ast, fn
            {:alias, _, [{:__aliases__, _, parts} | _]} ->
              parts == module_parts or Enum.take(parts, length(module_parts)) == module_parts

            {{:., _, [{:__aliases__, _, parts}, _]}, _, _} ->
              parts == module_parts or Enum.take(parts, length(module_parts)) == module_parts

            _ ->
              false
          end)

        refs = extract_fn_refs(test_ast)
        {module_referenced?, refs}
    end
  end

  defp extract_fn_refs(ast) do
    AST.find_all(ast, fn
      {{:., _, [{:__aliases__, _, _}, fn_name]}, _, args} when is_atom(fn_name) ->
        is_list(args)

      _ ->
        false
    end)
    |> Enum.map(fn {{:., _, [_, fn_name]}, _, args} ->
      {fn_name, length(args)}
    end)
    |> Enum.uniq()
  end

  defp build_diagnostics(source_file, source_ast, public_fns, uncovered, module_referenced?) do
    module_name = AST.extract_module_name(source_ast)
    total = length(public_fns)
    covered_count = total - length(uncovered)
    pct = if total == 0, do: 100, else: round(covered_count * 100 / total)

    cond do
      # Full direct coverage — nothing to report
      pct == 100 ->
        []

      # Module is referenced but no direct function refs — test goes through indirection
      not_direct_but_referenced?(module_referenced?, covered_count) ->
        [
          Diagnostic.info("7.14",
            title: "Indirect test coverage only",
            message:
              "#{module_name} test file references the module but no specific public functions",
            why:
              "Reference-based coverage detection looks for explicit calls to public functions in the test " <>
                "file. When the module is aliased but no functions are called directly, the rule can't tell " <>
                "whether each public function is actually exercised — it might be tested transitively or not " <>
                "at all. Direct references give you per-function confidence.",
            alternatives: [
              Fix.new(
                summary: "Add tests that call the public functions directly",
                detail:
                  "Even one assertion per public function gives the rule a clear signal and makes the test " <>
                    "file a usable reference for what the module promises.",
                applies_when: "The module has public functions that aren't transitively covered."
              ),
              Fix.new(
                summary: "Mark the module as indirectly covered if that's the design",
                detail:
                  "If the module is intentionally only tested via callers (a small adapter, a struct), " <>
                    "document the choice in a moduledoc note and add to the freeze baseline.",
                applies_when: "The transitive coverage is intentional."
              )
            ],
            references: ["ARCHITECTURE_RULES.md#7.14"],
            context: %{module: module_name, kind: :indirect_only},
            file: source_file,
            line: 1
          )
        ]

      # Partial or no coverage — report summary and uncovered list
      true ->
        builder =
          if severity_for(pct) == @warning_severity,
            do: &Diagnostic.warning/2,
            else: &Diagnostic.info/2

        [
          builder.("7.14",
            title: "Public API coverage gap",
            message:
              "#{module_name} coverage: #{covered_count}/#{total} public functions referenced (#{pct}%)",
            why:
              "Public functions are the contract a module exposes — every one should have at least one test " <>
                "reference so regressions are caught. Low coverage on public API surfaces means changes can " <>
                "ship without anything noticing they broke a consumer's expected behaviour.",
            alternatives: [
              Fix.new(
                summary: "Add tests for the uncovered functions",
                detail:
                  "Uncovered: #{format_fn_list(uncovered)}. Even minimal happy-path assertions are enough " <>
                    "to give the rule a signal and protect against regressions.",
                applies_when: "The functions are part of the supported API."
              ),
              Fix.new(
                summary: "Make uncovered functions private (`defp`) if they aren't really public",
                detail:
                  "Functions that are public only because they were `def` by reflex can be marked `defp`. " <>
                    "The rule treats them as internal and stops nagging.",
                applies_when: "The functions were exposed unintentionally."
              )
            ],
            references: ["ARCHITECTURE_RULES.md#7.14"],
            context: %{
              module: module_name,
              total_public: total,
              covered: covered_count,
              uncovered: Enum.map(uncovered, fn {n, a} -> "#{n}/#{a}" end),
              pct: pct
            },
            file: source_file,
            line: 1
          )
        ]
    end
  end

  defp not_direct_but_referenced?(module_referenced?, covered_count) do
    module_referenced? and covered_count == 0
  end

  defp severity_for(pct) when pct < 50, do: :warning
  defp severity_for(_pct), do: :info

  defp format_fn_list(fns) do
    fns
    |> Enum.take(5)
    |> Enum.map_join(", ", fn {name, arity} -> "#{name}/#{arity}" end)
  end

  # --- Extraction helpers ---

  defp collect_public_fns(ast) do
    {_, fns} =
      Macro.prewalk(ast, [], fn
        {:def, _, [{name, _, args} | _]} = node, acc when is_atom(name) ->
          arity = if is_list(args), do: length(args), else: 0

          if name in @ignored_functions or String.starts_with?(Atom.to_string(name), "__") do
            {node, acc}
          else
            {node, [{name, arity} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(fns)
  end

  # Map source file to a canonical lookup key.
  # lib/my_app/accounts.ex → "accounts" (if the test is at test/accounts_test.exs)
  # lib/my_app/accounts/user.ex → "accounts/user"
  #
  # The key drops the leading "lib/" and the app namespace directory
  # so it aligns with how tests are laid out.
  defp source_key(source_file) do
    source_file
    |> String.replace_prefix("./", "")
    |> String.replace_prefix("lib/", "")
    |> then(fn f ->
      # Handle absolute path case: /foo/bar/lib/my_app/...
      case String.split(f, "/lib/") do
        [_, rest] -> rest
        _ -> f
      end
    end)
    |> String.trim_trailing(".ex")
    |> String.split("/", parts: 2)
    |> case do
      [_app, rest] -> rest
      [only] -> only
    end
  end

  defp build_test_index(tests) do
    tests
    |> Enum.map(fn {file, ast} -> {test_key(file), ast} end)
    |> Enum.reject(fn {key, _} -> is_nil(key) end)
    |> Map.new()
  end

  # Map test file to same lookup key.
  # test/my_app/accounts_test.exs → "accounts" (after dropping app)
  # test/my_app/accounts/user_test.exs → "accounts/user"
  defp test_key(test_file) do
    test_file
    |> String.replace_prefix("./", "")
    |> String.replace_prefix("test/", "")
    |> then(fn f ->
      case String.split(f, "/test/") do
        [_, rest] -> rest
        _ -> f
      end
    end)
    |> String.trim_trailing(".exs")
    |> String.trim_trailing("_test")
    |> then(fn key ->
      # If the test file is under an app dir matching source structure, drop the app prefix
      # But many test suites flatten this (test/rules/otp/x_test.exs rather than test/archdo/rules/otp/x_test.exs)
      # So we just return the key as-is. Source keys also drop the first segment.
      key
    end)
  end

  defp ignore_source?(file, ast) do
    String.ends_with?(file, "/application.ex") or
      String.ends_with?(file, "_web.ex") or
      String.contains?(file, "/mix/") or
      String.contains?(file, "/migrations/") or
      AST.internal_module?(ast)
  end

  # --- Matrix formatting ---

  defp format_matrix(rows) do
    header = "\nArchdo — Test Coverage Gap Matrix\n"

    if rows == [] do
      [header, "\nNo source files analyzed.\n"]
    else
      totals = aggregate(rows)

      table_header = [
        "\n",
        :io_lib.format("~-50ts ~6ts ~6ts ~6ts ~6ts~n", [
          "Module",
          "Total",
          "Cov",
          "Gap",
          "%"
        ]),
        String.duplicate("-", 78),
        "\n"
      ]

      table_rows =
        Enum.map(rows, fn row ->
          :io_lib.format("~-50ts ~6w ~6w ~6w ~5w%~n", [
            truncate(row.module, 50),
            row.total,
            row.covered,
            row.uncovered,
            row.coverage_pct
          ])
        end)

      footer = [
        String.duplicate("-", 78),
        "\n",
        :io_lib.format("~-50ts ~6w ~6w ~6w ~5w%~n", [
          "TOTAL",
          totals.total,
          totals.covered,
          totals.uncovered,
          totals.pct
        ]),
        "\n"
      ]

      [header, table_header, table_rows, footer]
    end
  end

  defp aggregate(rows) do
    total = Enum.sum(Enum.map(rows, & &1.total))
    covered = Enum.sum(Enum.map(rows, & &1.covered))
    uncovered = total - covered
    pct = if total == 0, do: 0, else: round(covered * 100 / total)

    %{total: total, covered: covered, uncovered: uncovered, pct: pct}
  end

  defp truncate(str, max) do
    if String.length(str) > max do
      String.slice(str, 0, max - 3) <> "..."
    else
      str
    end
  end
end
