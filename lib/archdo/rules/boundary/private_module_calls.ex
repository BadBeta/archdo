defmodule Archdo.Rules.Boundary.PrivateModuleCalls do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{Config, Diagnostic, Fix, Graph}

  @impl true
  def id, do: "2.3"

  @impl true
  def description, do: "No external calls to @moduledoc false modules"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc """
  Graph-based: needs to know which modules are marked @moduledoc false.
  Takes the graph, config, and a set of private module names.
  """
  def analyze_graph(%Graph{} = graph, %Config{} = _config, private_modules) do
    graph.edges
    |> Enum.filter(fn edge ->
      MapSet.member?(private_modules, edge.target) and
        not same_namespace?(edge.source, edge.target) and
        edge.type == :call
    end)
    |> Enum.uniq_by(fn edge -> {edge.source, edge.target} end)
    |> Enum.map(fn edge ->
      parent_ns = parent_namespace(edge.target)

      Diagnostic.warning("2.3",
        title: "Call into private module",
        message: "#{edge.source} calls #{edge.target}, which is marked `@moduledoc false`",
        why:
          "`@moduledoc false` is the project's signal that the module is internal — its functions and " <>
            "structure are free to change without notice. External callers that reach in lock the internals " <>
            "in place: any rename, restructure, or removal becomes a breaking change to consumers who weren't " <>
            "supposed to depend on it. The boundary is documented; the call breaks it.",
        alternatives: [
          Fix.new(
            summary: "Switch to the public API at #{parent_ns}",
            detail:
              "Find (or add) a public function on #{parent_ns} that does what the call needs. Update the " <>
                "caller to use it. The internal module stays internal and the dependency points at the " <>
                "supported surface.",
            applies_when: "There's an obvious public counterpart, or one can be added."
          ),
          Fix.new(
            summary: "Promote the called module to public if other contexts genuinely need it",
            detail:
              "If multiple consumers across the codebase need the helper, it isn't really internal. Replace " <>
                "`@moduledoc false` with a real moduledoc, document the API, and accept the maintenance burden.",
            applies_when: "The module is needed by enough callers that it should be public."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#2.3"],
        context: %{source: edge.source, target: edge.target, parent: parent_ns},
        file: edge.file,
        line: edge.line
      )
    end)
  end

  defp same_namespace?(source, target) do
    source_parts = String.split(source, ".")
    target_parts = String.split(target, ".")

    # Same parent namespace (e.g., MyApp.Accounts.X and MyApp.Accounts.Y)
    source_parent = Enum.take(source_parts, length(source_parts) - 1)
    target_parent = Enum.take(target_parts, length(target_parts) - 1)

    source_parent == target_parent or
      # Source is the parent of target
      source_parts == target_parent or
      # They share the same top-2 namespace
      Enum.take(source_parts, 2) == Enum.take(target_parts, 2)
  end

  defp parent_namespace(module_name) do
    module_name
    |> String.split(".")
    |> Enum.take(-2)
    |> Enum.take(1)
    |> then(fn
      [] -> module_name
      _parts ->
        module_name
        |> String.split(".")
        |> Enum.drop(-1)
        |> Enum.join(".")
    end)
  end
end
