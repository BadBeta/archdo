defmodule Archdo.Rules.Boundary.FrameworkInDomain do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{Config, Diagnostic, Fix, Graph}

  @impl true
  def id, do: "1.1b"

  @impl true
  def description, do: "Domain modules must not depend on framework-specific packages"

  def analyze_graph(%Graph{} = graph, %Config{} = config) do
    graph.edges
    |> Enum.filter(fn edge ->
      source_layer = Config.classify_module(config, edge.source)
      source_layer == :domain and Config.framework_module?(config, edge.target)
    end)
    |> Enum.uniq_by(fn edge -> {edge.source, edge.target} end)
    |> Enum.map(fn edge ->
      Diagnostic.warning("1.1b",
        title: "Framework call in domain layer",
        message: "Domain module #{edge.source} depends on framework module #{edge.target}",
        why:
          "The point of having a domain layer is that it survives framework changes: swap Phoenix for Plug, " <>
            "swap Ecto for something else, and the business rules don't move. As soon as a domain module imports " <>
            "framework code, that promise is broken — the domain becomes a framework plugin and cannot be tested " <>
            "or reused without the framework runtime.",
        alternatives: [
          Fix.new(
            summary: "Move the framework-touching code to the interface layer",
            detail:
              "Lift the call to a controller, channel, or context module in the interface/web layer. The domain " <>
                "function takes plain data as input and returns plain data — the framework code stays at the edge.",
            applies_when:
              "The call is genuinely a framework concern (request/response, channel, websocket)."
          ),
          Fix.new(
            summary: "Define a behaviour in the domain and inject the framework adapter",
            detail:
              "If the domain needs the capability (e.g. publish events, send a notification) but shouldn't " <>
                "know about the framework, declare a behaviour in the domain and provide the framework-specific " <>
                "implementation in the outer layer. Inject it via config or function arg.",
            applies_when: "The domain needs the capability, not the implementation."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#1.1b"],
        context: %{source: edge.source, target: edge.target},
        file: edge.file,
        line: edge.line
      )
    end)
  end
end
