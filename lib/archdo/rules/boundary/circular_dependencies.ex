defmodule Archdo.Rules.Boundary.CircularDependencies do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Config, Diagnostic, Fix, Graph}

  @impl true
  def id, do: "1.3"

  @impl true
  def description, do: "No circular dependencies between contexts"

  def analyze_graph(%Graph{} = graph, %Config{} = config) do
    cycles_for_contexts(config.contexts, graph)
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # the empty-contexts list (no contexts → no analysis possible).
  defp cycles_for_contexts([], _graph), do: []

  defp cycles_for_contexts(contexts, graph) do
    cycles = Graph.find_cycles(graph, contexts)
    Enum.map(cycles, &cycle_diagnostic(&1, graph))
  end

  defp cycle_diagnostic(cycle, graph) do
    cycle_str = Enum.map_join(cycle, " → ", &AST.module_name/1)

    # Use the first module's file for location
    first = AST.module_name(hd(cycle))
    second = AST.module_name(Enum.at(cycle, 1))

    graph.edges
    |> find_cycle_edge(first, second)
    |> build_cycle_diag(cycle_str)
  end

  defp find_cycle_edge(edges, first, second) do
    Enum.find(edges, fn e ->
      (e.source == first or String.starts_with?(e.source, first <> ".")) and
        (e.target == second or String.starts_with?(e.target, second <> "."))
    end)
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # the edge's nil-vs-struct shape. Eliminates the awkward
  # 2-tuple destructure-from-helper pattern; the diagnostic builder
  # owns the file/line defaulting directly.
  defp build_cycle_diag(nil, cycle_str), do: do_build_cycle_diag(cycle_str, "unknown", 0)
  defp build_cycle_diag(edge, cycle_str), do: do_build_cycle_diag(cycle_str, edge.file, edge.line)

  defp do_build_cycle_diag(cycle_str, file, line) do
    Diagnostic.error("1.3",
      title: "Circular dependency between contexts",
      message: "Circular context dependency: #{cycle_str}",
      why:
        "Cycles between contexts make compilation order ambiguous, defeat refactoring (you can't change " <>
          "either side without touching the other), and almost always indicate that the contexts have leaked " <>
          "into each other. They also break the mental model that makes bounded contexts useful: there is " <>
          "no longer a 'depends on' direction you can reason about.",
      alternatives: [
        Fix.new(
          summary: "Break the cycle with PubSub or events",
          detail:
            "Replace one direction of the cycle with a published event the other side subscribes to. " <>
              "The dependency arrow becomes 'publishes' rather than 'calls', and there is no compile-time " <>
              "edge between the modules.",
          applies_when:
            "The cycle exists because one side needs to react to the other's state changes."
        ),
        Fix.new(
          summary: "Extract shared logic into a third context",
          detail:
            "If both sides reach into each other for a shared concept, that concept probably wants its " <>
              "own context. Move the shared modules out and have both originals depend on the new shared " <>
              "context — the cycle is replaced with a shared parent.",
          applies_when: "Both sides reach into each other for the same concept."
        ),
        Fix.new(
          summary: "Define a behaviour and inject the implementation",
          detail:
            "Have one side declare an abstract behaviour and the other side implement it. Inject the " <>
              "implementation via configuration so neither side `import`s the other directly.",
          applies_when: "The cycle is between a policy and a mechanism."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#1.3"],
      context: %{cycle: cycle_str},
      file: file,
      line: line
    )
  end

end
