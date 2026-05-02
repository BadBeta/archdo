defmodule Archdo.Rules.CE.ContractDensitySpecs do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-12. Public API modules (Ecto schemas,
  # Supervisors, paths in public_api_paths) with fewer than 80% of
  # public functions covered by `@spec`s. A focused subset of CE-11:
  # spec coverage in particular is verifiable by Dialyzer and breaks
  # silently at compile time when missing — worth flagging on its own.

  alias Archdo.{AST, Diagnostic, Fix, IrreversibleDecision}

  @spec_coverage_threshold 0.80

  @impl true
  def id, do: "CE-12"

  @impl true
  def description,
    do: "Public API module with low @spec coverage (Ecto schemas, Supervisors, public-API paths)"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc "Project-level. Returns one Diagnostic per under-spec'd public API module."
  @spec analyze_project([{String.t(), Macro.t()}], keyword()) :: [Diagnostic.t()]
  def analyze_project(file_asts, opts \\ []) do
    file_asts
    |> Enum.reject(fn {file, _} -> AST.test_file?(file) end)
    |> Enum.flat_map(&maybe_diagnostic(&1, opts))
  end

  defp maybe_diagnostic({file, ast}, opts) do
    cond do
      not IrreversibleDecision.candidate?(file, ast, opts) -> []
      specs_pending?(ast) -> []
      true -> compute_and_flag(file, ast)
    end
  end

  defp specs_pending?(ast) do
    AST.contains?(ast, fn
      {:@, _, [{:archdo_specs_pending, _, _}]} -> true
      _ -> false
    end)
  end

  defp compute_and_flag(file, ast) do
    publics = AST.extract_functions(ast, :public)
    spec_set = AST.spec_keys(ast)

    case length(publics) do
      0 ->
        []

      total ->
        with_specs = Enum.count(publics, fn {n, a, _, _, _} -> {n, a} in spec_set end)
        coverage = with_specs / total

        case coverage < @spec_coverage_threshold do
          true -> [build_diagnostic(file, ast, with_specs, total, coverage)]
          false -> []
        end
    end
  end

  defp build_diagnostic(file, ast, with_specs, total, coverage) do
    module = AST.extract_module_name(ast)
    pct = (coverage * 100) |> Float.round(0) |> trunc()
    threshold_pct = trunc(@spec_coverage_threshold * 100)

    Diagnostic.warning("CE-12",
      title: "Public API module with low @spec coverage",
      message:
        "#{module}: #{with_specs}/#{total} public functions have @spec (#{pct}%, " <>
          "below #{threshold_pct}% threshold). Public APIs without specs cannot be " <>
          "Dialyzer-verified.",
      why:
        "Public APIs (Ecto schemas, supervisors, modules under public_api_paths) " <>
          "are irreversible decisions — once published, callers depend on the shape. " <>
          "Without @spec, callers must read source to understand the contract; " <>
          "breaking changes are silent at compile time; Dialyzer cannot verify " <>
          "callers honour the API.",
      alternatives: [
        Fix.new(
          summary: "Add @spec to each public function",
          detail:
            "This is a finite, well-scoped task per module. Even a loose @spec " <>
              "(`@spec foo(map()) :: term()`) is better than none — it documents " <>
              "the entry shape and lets Dialyzer trace from there.",
          applies_when: "The function's contract is stable enough to declare."
        ),
        Fix.new(
          summary: "Mark @archdo_specs_pending with a deadline",
          detail:
            "If specs are coming but not yet written, declare the intent: " <>
              "`@archdo_specs_pending \"WIP — adding specs in #1234\"` at module level.",
          applies_when: "Specs are planned but not yet written."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-12"],
      context: %{module: module, spec_coverage: coverage, with_specs: with_specs, total: total},
      file: file,
      line: 1
    )
  end
end
