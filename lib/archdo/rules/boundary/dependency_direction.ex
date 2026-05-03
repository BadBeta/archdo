defmodule Archdo.Rules.Boundary.DependencyDirection do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{Config, Diagnostic, Fix, Graph}

  @impl true
  def id, do: "1.1"

  @impl true
  def description, do: "Dependencies must flow inward (hexagonal architecture)"

  @doc """
  Graph-based analysis. Takes the full module graph and config.
  """
  def analyze_graph(%Graph{} = graph, %Config{} = config) do
    graph.edges
    |> Enum.filter(fn edge ->
      source_layer = Config.classify_module(config, edge.source)
      target_layer = Config.classify_module(config, edge.target)

      source_layer != :unknown and
        target_layer != :unknown and
        not Config.allowed_dep?(config, source_layer, target_layer)
    end)
    |> Enum.reject(fn edge -> tolerated?(edge, config) end)
    |> Enum.uniq_by(fn edge -> {edge.source, edge.target} end)
    |> Enum.map(fn edge ->
      source_layer = Config.classify_module(config, edge.source)
      target_layer = Config.classify_module(config, edge.target)

      Diagnostic.error("1.1",
        title: "Inward dependency violation",
        message: "#{edge.source} (#{source_layer}) depends on #{edge.target} (#{target_layer})",
        why:
          "Hexagonal/Onion architecture requires dependencies to point inward: outer layers (web, infrastructure) " <>
            "may know about inner layers (domain, business rules), but never the reverse. When a #{source_layer} " <>
            "module reaches into a #{target_layer} module, the inner layer becomes coupled to the outer layer's " <>
            "lifecycle and cannot be tested or reused without it. Over time these violations make the domain " <>
            "indistinguishable from the framework that surrounds it.",
        alternatives: [
          Fix.new(
            summary: "Define a behaviour in the inner layer and implement it in the outer layer",
            detail:
              "Replace the direct call with a behaviour declared in #{source_layer} (an abstract port). " <>
                "Implement that behaviour in #{target_layer} (a concrete adapter) and inject the implementation " <>
                "via configuration or function arguments. The dependency arrow now flips: the outer layer " <>
                "depends on the inner-layer behaviour, not the other way around.",
            applies_when: "The dependency is needed but the direction must be inverted."
          ),
          Fix.new(
            summary: "Move the offending logic to the outer layer",
            detail:
              "If the call exists because business logic accidentally landed inside an inner module, move " <>
                "that logic to where it really belongs (typically the outer layer). The inner layer no longer " <>
                "needs to call out and the violation disappears.",
            applies_when: "The dependency exists because logic was misplaced."
          ),
          Fix.new(
            summary: "Restructure the contexts so the dependency direction makes sense",
            detail:
              "Sometimes the layer classification is wrong: the module flagged as #{source_layer} should " <>
                "actually be #{target_layer} or vice versa. Update `.archdo.exs` (or the directory layout) so " <>
                "the layers reflect the real architecture.",
            applies_when: "The layer classification is inaccurate."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#1.1"],
        context: %{
          source: edge.source,
          target: edge.target,
          source_layer: source_layer,
          target_layer: target_layer
        },
        file: edge.file,
        line: edge.line
      )
    end)
  end

  defp tolerated?(edge, _config) do
    target = edge.target

    # Ecto is accepted in domain
    # Phoenix.PubSub is general-purpose
    String.starts_with?(target, "Ecto.") or
      String.starts_with?(target, "Phoenix.PubSub")
  end
end
