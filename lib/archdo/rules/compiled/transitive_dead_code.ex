defmodule Archdo.Rules.Compiled.TransitiveDeadCode do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.Compiled
  alias Archdo.Compiled.Graph
  alias Archdo.{Diagnostic, Fix}

  @impl true
  def id, do: "6.25"

  @impl true
  def description, do: "Function only called from dead functions — transitively dead"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @spec analyze_compiled(Graph.t()) :: [Diagnostic.t()]
  def analyze_compiled(%Graph{modules: modules} = graph) do
    # Only consider project modules (those in the graph's module map)
    project_modules = MapSet.new(Map.keys(modules))

    dead_roots =
      graph
      |> Compiled.dead_functions()
      |> MapSet.new(fn %{module: m, function: f, arity: a} -> {m, f, a} end)

    # Walk outward from dead roots: if ALL callers of a function are dead,
    # the function is transitively dead. Only check project functions.
    find_transitive_dead(graph, dead_roots, MapSet.new(), project_modules)
    |> MapSet.difference(dead_roots)
    |> Enum.filter(fn {mod, _f, _a} -> MapSet.member?(project_modules, mod) end)
    |> Enum.map(&build_diagnostic/1)
  end

  defp find_transitive_dead(graph, dead_set, visited, project_modules) do
    # For each dead function, check its callees (only project functions)
    new_dead =
      dead_set
      |> MapSet.difference(visited)
      |> Enum.flat_map(fn mfa ->
        Compiled.callees_of(graph, mfa)
        |> Enum.map(& &1.callee)
        |> Enum.filter(fn {mod, _f, _a} = callee ->
          MapSet.member?(project_modules, mod) and
            all_callers_dead?(graph, callee, dead_set)
        end)
      end)
      |> MapSet.new()

    updated_visited = MapSet.union(visited, dead_set)

    case MapSet.size(new_dead) do
      0 ->
        dead_set

      _ ->
        expanded = MapSet.union(dead_set, new_dead)
        find_transitive_dead(graph, expanded, updated_visited, project_modules)
    end
  end

  defp all_callers_dead?(graph, mfa, dead_set) do
    callers = Compiled.callers_of(graph, mfa)

    case callers do
      [] -> false
      _ -> Enum.all?(callers, fn call -> MapSet.member?(dead_set, call.caller) end)
    end
  end

  defp build_diagnostic({module, func, arity}) do
    mod_name =
      module
      |> Atom.to_string()
      |> String.replace_leading("Elixir.", "")

    Diagnostic.info("6.25",
      title: "Transitively dead function",
      message:
        "#{mod_name}.#{func}/#{arity} is only called from dead functions — " <>
          "removing the dead callers would leave this function unreachable",
      why:
        "This function has callers, but every caller is itself dead code (rule 6.24). " <>
          "If the dead callers are removed, this function becomes orphaned. " <>
          "Consider removing the entire dead call chain together.",
      alternatives: [
        Fix.new(
          summary: "Remove along with dead callers",
          detail: "Delete this function and its dead callers as a batch cleanup.",
          applies_when: "The entire call chain is confirmed dead."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.25"],
      context: %{module: mod_name, function: "#{func}/#{arity}"},
      file: "lib",
      line: 0
    )
  end
end
