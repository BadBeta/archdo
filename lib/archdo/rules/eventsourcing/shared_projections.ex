defmodule Archdo.Rules.EventSourcing.SharedProjections do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{Diagnostic, Fix, Graph}

  @impl true
  def id, do: "8.4"

  @impl true
  def description, do: "Projectors must not share read models"

  @doc """
  Graph-based: detect multiple projector modules writing to the same Ecto schema.
  Only applies when Commanded is actually in use.
  """
  def analyze_graph(%Graph{} = graph, _config) do
    if commanded_project?(graph) do
      find_shared_projections(graph)
    else
      []
    end
  end

  defp commanded_project?(%Graph{} = graph) do
    Enum.any?(graph.edges, fn edge ->
      String.starts_with?(edge.target, "Commanded.")
    end)
  end

  defp find_shared_projections(%Graph{} = graph) do
    projectors =
      graph.modules
      |> MapSet.to_list()
      |> Enum.filter(&projector_module?/1)

    schema_pairs =
      Enum.flat_map(projectors, fn projector ->
        for edge <- Graph.dependencies(graph, projector),
            schema_reference?(edge.target),
            do: {edge.target, projector}
      end)

    schema_usage =
      for {schema, projs} <-
            Enum.group_by(schema_pairs, fn {schema, _} -> schema end, fn {_, projector} ->
              projector
            end),
          do: {schema, Enum.uniq(projs)}

    for {schema, projectors_list} <- schema_usage,
        length(projectors_list) > 1 do
      projector_names = Enum.join(projectors_list, ", ")

      Diagnostic.warning("8.4",
        title: "Read model shared between projectors",
        message: "Schema #{schema} is referenced by multiple projectors: #{projector_names}",
        why:
          "Each projector owns its read model so it can be rebuilt independently from the event stream. When " <>
            "two projectors write to the same schema, rebuilding one wipes or duplicates rows the other still " <>
            "needs, and the order in which they replay starts to matter. The coupling is invisible until you try to rebuild.",
        alternatives: [
          Fix.new(
            summary: "Give each projector its own table",
            detail:
              "Split the shared schema into per-projector tables (e.g. `ProjectorA.Account`, " <>
                "`ProjectorB.Account`). Migrate the dependent projector to read from its own table. Both can be " <>
                "rebuilt independently and the read side picks the right one.",
            applies_when: "The two projectors really need different views of the data."
          ),
          Fix.new(
            summary: "Merge the projectors if they should always evolve together",
            detail:
              "If both projectors only ever update the same rows in lockstep, fold them into a single projector " <>
                "module so the lifecycle is one unit and there is no race on rebuild.",
            applies_when: "The two projectors are conceptually one read model that was split."
          ),
          Fix.new(
            summary: "Treat the schema as reference data and ignore the warning",
            detail:
              "If the schema is a static lookup table (countries, currencies) populated outside the event " <>
                "stream, projectors only read from it; add it to the freeze baseline.",
            applies_when: "The schema is reference data, not a real projection."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#8.4"],
        context: %{schema: schema, projectors: projectors_list},
        file: "multiple",
        line: 0
      )
    end
  end

  defp projector_module?(name) do
    # A real Commanded projector is typically in a "Projectors" or "Projections" namespace
    # and ends with "Projector" or similar. Exclude generic rule/analysis modules.
    (String.ends_with?(name, "Projector") or String.ends_with?(name, "Projection")) and
      not String.starts_with?(name, "Archdo.")
  end

  defp schema_reference?(target) do
    # Exclude standard library modules
    not String.contains?(target, "Projector") and
      not String.starts_with?(target, "Ecto.") and
      not String.starts_with?(target, "Commanded.") and
      target not in ~w(Enum String List Map MapSet Keyword Process Kernel IO File Path)
  end
end
