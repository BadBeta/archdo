defmodule Archdo.Rules.Testing.MissingBoundaryTests do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @min_public_functions 8
  @coverage_threshold 0.30

  @impl true
  def id, do: "7.28"

  @impl true
  def description, do: "Context facade module has test file but exercises < 30% of public API"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc """
  Project-level rule. Takes file_asts (list of {file, ast} tuples).
  Detects context facades where the test file covers a small fraction of the public API.
  """
  @spec analyze_project([{String.t(), Macro.t()}]) :: [Diagnostic.t()]
  def analyze_project(file_asts) do
    source_asts = Enum.reject(file_asts, fn {file, _} -> AST.test_file?(file) end)
    test_asts = Enum.filter(file_asts, fn {file, _} -> AST.test_file?(file) end)

    source_asts
    |> Enum.filter(&context_facade?/1)
    |> Enum.flat_map(&check_coverage(&1, test_asts))
  end

  defp context_facade?({file, _ast}) do
    # A context facade is a file like lib/app/accounts.ex that has
    # a corresponding directory lib/app/accounts/
    case String.ends_with?(file, ".ex") do
      false ->
        false

      true ->
        dir = String.replace_suffix(file, ".ex", "")
        File.dir?(dir)
    end
  end

  defp check_coverage({file, ast}, test_asts) do
    public_fns =
      ast
      |> AST.extract_functions(:public)
      |> Enum.map(fn {name, _arity, _meta, _args, _body} -> name end)
      |> Enum.uniq()

    enough_publics?(length(public_fns) >= @min_public_functions, file, ast, public_fns, test_asts)
  end

  # §§ elixir-implementing: §2.1 — boolean → multi-clause head, then
  # dispatch on test-AST presence (nil vs {file, ast}) via a second
  # multi-clause head. Each stage is depth 1.
  defp enough_publics?(false, _file, _ast, _public_fns, _test_asts), do: []

  defp enough_publics?(true, file, ast, public_fns, test_asts) do
    test_file = source_to_test_path(file)
    coverage_check(find_test_ast(test_file, test_asts), file, ast, public_fns)
  end

  defp coverage_check(nil, _file, _ast, _public_fns), do: []

  defp coverage_check({_test_file, test_ast}, file, ast, public_fns) do
    tested_fns = extract_tested_function_names(test_ast)
    covered = MapSet.intersection(MapSet.new(public_fns), tested_fns)
    coverage = MapSet.size(covered) / length(public_fns)

    diagnostic_if_below_threshold(
      coverage < @coverage_threshold,
      coverage,
      covered,
      public_fns,
      file,
      ast
    )
  end

  defp diagnostic_if_below_threshold(false, _coverage, _covered, _public_fns, _file, _ast), do: []

  defp diagnostic_if_below_threshold(true, coverage, covered, public_fns, file, ast) do
    [build_coverage_diag(coverage, covered, public_fns, file, ast)]
  end

  defp build_coverage_diag(coverage, covered, public_fns, file, ast) do
    module_name = AST.extract_module_name(ast)
    pct = Float.round(coverage * 100, 1)

    Diagnostic.info("7.28",
      title: "Low boundary test coverage",
      message:
        "#{module_name} has #{length(public_fns)} public functions but test covers ~#{pct}% " <>
          "(#{MapSet.size(covered)}/#{length(public_fns)})",
      why:
        "Context facades are the primary API boundary for a domain. When a context " <>
          "has many public functions but few are exercised in tests, regressions in " <>
          "the untested functions go undetected. Boundary tests are the most valuable " <>
          "tests in a Phoenix application because they verify the contract other modules depend on.",
      alternatives: [
        Fix.new(
          summary: "Add tests for the uncovered public functions",
          detail:
            "The following functions appear untested: " <>
              "#{inspect(Enum.sort(MapSet.to_list(MapSet.difference(MapSet.new(public_fns), covered))))}. " <>
              "Add at least a happy-path test for each.",
          applies_when: "The functions contain meaningful logic."
        ),
        Fix.new(
          summary: "Consolidate the public API if some functions are unused",
          detail:
            "If some public functions are never called from outside the context, " <>
              "make them private (defp). A smaller public API is easier to test thoroughly.",
          applies_when: "Some public functions are internal helpers exposed accidentally."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#7.28"],
      context: %{
        module: module_name,
        public_count: length(public_fns),
        covered_count: MapSet.size(covered),
        coverage_pct: pct
      },
      file: file,
      line: 1
    )
  end

  defp source_to_test_path(file) do
    file
    |> String.replace_prefix("lib/", "test/")
    |> String.replace_suffix(".ex", "_test.exs")
  end

  defp find_test_ast(test_file, test_asts) do
    Enum.find(test_asts, fn {file, _ast} ->
      file == test_file or String.ends_with?(file, Path.basename(test_file))
    end)
  end

  defp extract_tested_function_names(test_ast) do
    {_, names} =
      Macro.prewalk(test_ast, MapSet.new(), fn
        # describe "function_name/arity" or describe "function_name"
        {:describe, _, [desc | _]} = node, acc when is_binary(desc) ->
          case extract_fn_name_from_desc(desc) do
            nil -> {node, acc}
            name -> {node, MapSet.put(acc, name)}
          end

        # Direct function calls in test bodies: Module.function(...)
        {{:., _, [_, func]}, _, _} = node, acc when is_atom(func) ->
          {node, MapSet.put(acc, func)}

        # Bare function calls in test bodies
        {func, _, args} = node, acc when is_atom(func) and is_list(args) ->
          {node, MapSet.put(acc, func)}

        node, acc ->
          {node, acc}
      end)

    names
  end

  defp extract_fn_name_from_desc(desc) do
    # Match "function_name/2" or "function_name" patterns. Use
    # to_existing_atom — if the test description doesn't correspond to
    # a real function name in the atom table, it can't be testing one.
    # (Also avoids accumulating atoms for malformed test descriptions.)
    with [_, name] <- Regex.run(~r/^(\w+)(?:\/\d+)?$/, desc),
         {:ok, atom} <- AST.try_existing_atom(name) do
      atom
    else
      _ -> nil
    end
  end
end
