defmodule Archdo.Rules.Boundary.CircularDependencies do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Config, Diagnostic, Fix, Graph}

  @impl true
  def id, do: "1.3"

  @impl true
  def description, do: "No circular dependencies between contexts"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  def analyze_graph(%Graph{} = graph, %Config{} = config) do
    contexts = config.contexts

    if contexts == [] do
      []
    else
      cycles = Graph.find_cycles(graph, contexts)

      Enum.map(cycles, fn cycle ->
        cycle_str = Enum.map_join(cycle, " → ", &normalize/1)

        # Use the first module's file for location
        first = normalize(hd(cycle))
        second = normalize(Enum.at(cycle, 1))

        edge =
          Enum.find(graph.edges, fn e ->
            (e.source == first or String.starts_with?(e.source, first <> ".")) and
              (e.target == second or String.starts_with?(e.target, second <> "."))
          end)

        file = if edge, do: edge.file, else: "unknown"
        line = if edge, do: edge.line, else: 0

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
              applies_when: "The cycle exists because one side needs to react to the other's state changes."
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
      end)
    end
  end

  defp normalize(mod) when is_atom(mod), do: AST.module_name(mod)
  defp normalize(mod) when is_binary(mod), do: mod
end
