defmodule Archdo.Rules.Boundary.RepoInInterface do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{Config, Diagnostic, Fix, Graph}

  @impl true
  def id, do: "1.4"

  @impl true
  def description, do: "No direct Repo access from interface layer"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  def analyze_graph(%Graph{} = graph, %Config{} = config) do
    graph.edges
    |> Enum.filter(fn edge ->
      source_layer = Config.classify_module(config, edge.source)
      source_layer == :interface and repo_reference?(edge.target)
    end)
    |> Enum.reject(&tolerated?/1)
    |> Enum.uniq_by(fn edge -> {edge.source, edge.target} end)
    |> Enum.map(fn edge ->
      Diagnostic.warning("1.4",
        title: "Repo access from interface layer",
        message: "Interface module #{edge.source} calls #{edge.target} (Repo) directly",
        why:
          "When controllers/views/channels query the Repo themselves, they bypass the context's public API and " <>
            "embed query knowledge in the interface layer. The same query gets duplicated across handlers, " <>
            "the context can no longer enforce invariants, and changing the schema requires hunting through the " <>
            "web layer instead of touching one place.",
        alternatives: [
          Fix.new(
            summary: "Add a public function to the relevant context that returns the data",
            detail:
              "Move the query into the context module (e.g. `Accounts.list_users/1`) and have the controller " <>
                "call the context. The context owns the query, the interface only renders.",
            applies_when: "The data has a clear owning context."
          ),
          Fix.new(
            summary: "Expose a query module from the context if the call site needs flexibility",
            detail:
              "If the interface really does need to compose queries (admin filters, search forms), expose a " <>
                "query-builder module from the context (`Accounts.Users.Query`) that returns Ecto queryables. " <>
                "The interface composes the query but never touches the Repo.",
            applies_when: "The interface needs flexible filtering on top of the context's data."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#1.4"],
        context: %{source: edge.source, target: edge.target},
        file: edge.file,
        line: edge.line
      )
    end)
  end

  defp repo_reference?(target) do
    String.ends_with?(target, ".Repo") or
      String.ends_with?(target, "Repo") or
      target == "Ecto.Query"
  end

  defp tolerated?(edge) do
    # import Ecto.Query is tolerated in some patterns
    edge.type == :alias
  end
end
