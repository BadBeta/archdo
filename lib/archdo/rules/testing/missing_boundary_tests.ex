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

    public_count = length(public_fns)

    case public_count >= @min_public_functions do
      false ->
        []

      true ->
        test_file = source_to_test_path(file)

        case find_test_ast(test_file, test_asts) do
          nil ->
            []

          {_test_file, test_ast} ->
            tested_fns = extract_tested_function_names(test_ast)
            covered = MapSet.intersection(MapSet.new(public_fns), tested_fns)
            coverage = MapSet.size(covered) / public_count

            case coverage < @coverage_threshold do
              false ->
                []

              true ->
                module_name = AST.extract_module_name(ast)
                pct = Float.round(coverage * 100, 1)

                [
                  Diagnostic.info("7.28",
                    title: "Low boundary test coverage",
                    message:
                      "#{module_name} has #{public_count} public functions but test covers ~#{pct}% " <>
                        "(#{MapSet.size(covered)}/#{public_count})",
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
                        applies_when:
                          "Some public functions are internal helpers exposed accidentally."
                      )
                    ],
                    references: ["ARCHITECTURE_RULES.md#7.28"],
                    context: %{
                      module: module_name,
                      public_count: public_count,
                      covered_count: MapSet.size(covered),
                      coverage_pct: pct
                    },
                    file: file,
                    line: 1
                  )
                ]
            end
        end
    end
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
    # Match "function_name/2" or "function_name" patterns
    case Regex.run(~r/^(\w+)(?:\/\d+)?$/, desc) do
      [_, name] -> String.to_atom(name)
      _ -> nil
    end
  end
end
