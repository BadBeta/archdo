defmodule Archdo.Rules.Compiled.CircularContextDeps do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.Compiled
  alias Archdo.{Diagnostic, Fix}

  @impl true
  def id, do: "1.24"

  @impl true
  def description,
    do:
      "Circular context dependencies — Context A depends on Context B which depends on Context A"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc """
  Compiled-mode analysis: detect context-level dependency cycles.
  """
  @spec analyze_compiled(Compiled.t()) :: [Diagnostic.t()]
  def analyze_compiled(graph) do
    contexts = Compiled.discover_contexts(graph)

    # Build a context-level adjacency map: context_name => [dependent_context_names]
    adjacency = build_context_adjacency(graph, contexts)

    # Find cycles using DFS
    adjacency
    |> find_cycles()
    |> Enum.map(&build_diagnostic/1)
  end

  # Build a map of context_name => MapSet of context names that this context calls into.
  defp build_context_adjacency(graph, contexts) do
    calls_by_module = Compiled.calls_by_module(graph)

    # Build a lookup: module => context_name
    module_to_context =
      for ctx <- contexts,
          member <- ctx.members,
          into: %{},
          do: {member, ctx.context}

    context_names = MapSet.new(contexts, & &1.context)

    Map.new(contexts, &context_deps_entry(&1, calls_by_module, module_to_context, context_names))
  end

  defp context_deps_entry(ctx, calls_by_module, module_to_context, context_names) do
    deps =
      ctx.members
      |> Enum.flat_map(&callees_of_member(&1, calls_by_module))
      |> Enum.map(&Map.get(module_to_context, &1))
      |> Enum.filter(&valid_dep_context?(&1, ctx.context, context_names))
      |> Enum.uniq()

    {ctx.context, deps}
  end

  defp callees_of_member(member, calls_by_module) do
    calls_by_module
    |> Map.get(member, [])
    |> Enum.map(fn call -> elem(call.callee, 0) end)
  end

  defp valid_dep_context?(dep_ctx, own_ctx, context_names) do
    dep_ctx != nil and dep_ctx != own_ctx and MapSet.member?(context_names, dep_ctx)
  end

  # DFS cycle detection. Returns a list of cycles, each being a list of context names.
  # Deduplicates by normalizing cycles (rotate to smallest element first).
  defp find_cycles(adjacency) do
    all_nodes = Map.keys(adjacency)

    all_nodes
    |> Enum.flat_map(fn start_node ->
      dfs_find_cycles(adjacency, start_node, [start_node], MapSet.new([start_node]))
    end)
    |> Enum.map(&normalize_cycle/1)
    |> Enum.uniq()
  end

  defp dfs_find_cycles(adjacency, current, path, visited) do
    neighbors = Map.get(adjacency, current, [])
    Enum.flat_map(neighbors, &cycles_for_neighbor(&1, adjacency, path, visited))
  end

  defp cycles_for_neighbor(neighbor, adjacency, path, visited) do
    classify_neighbor_for_cycle(neighbor, List.last(path), MapSet.member?(visited, neighbor))
    |> handle_neighbor_kind(neighbor, adjacency, path, visited)
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # the (cycle-closing? / already-visited?) classifier tag.
  defp classify_neighbor_for_cycle(neighbor, start_node, _visited?) when neighbor == start_node, do: :cycle_complete
  defp classify_neighbor_for_cycle(_neighbor, _start_node, true), do: :already_visited
  defp classify_neighbor_for_cycle(_neighbor, _start_node, false), do: :recurse

  defp handle_neighbor_kind(:cycle_complete, _neighbor, _adjacency, path, _visited), do: [Enum.reverse(path)]
  defp handle_neighbor_kind(:already_visited, _neighbor, _adjacency, _path, _visited), do: []

  defp handle_neighbor_kind(:recurse, neighbor, adjacency, path, visited) do
    dfs_find_cycles(adjacency, neighbor, [neighbor | path], MapSet.put(visited, neighbor))
  end

  # Normalize a cycle by rotating so the lexicographically smallest element is first.
  defp normalize_cycle(cycle) do
    min_elem = Enum.min(cycle)
    idx = Enum.find_index(cycle, fn c -> c == min_elem end)
    {tail, head} = Enum.split(cycle, idx)
    head ++ tail
  end

  defp build_diagnostic(cycle) do
    cycle_str = Enum.join(cycle, " -> ") <> " -> " <> List.first(cycle)

    Diagnostic.warning("1.24",
      title: "Circular context dependency",
      message: "Context-level cycle detected: #{cycle_str}",
      why:
        "Contexts should form a directed acyclic graph — each context depends on " <>
          "lower-level contexts but never circularly. A cycle means changes in any " <>
          "context in the loop can cascade to all others, making the system brittle " <>
          "and hard to reason about. Circular dependencies also prevent independent " <>
          "testing and deployment of contexts.",
      alternatives: [
        Fix.new(
          summary: "Introduce a shared dependency context",
          detail:
            "Extract the shared concepts that cause the cycle into a new context " <>
              "that both #{List.first(cycle)} and #{List.last(cycle)} depend on, " <>
              "breaking the circular reference.",
          applies_when: "Both contexts share common domain concepts."
        ),
        Fix.new(
          summary: "Use behaviours or protocols to invert the dependency",
          detail:
            "Define a behaviour in the lower-level context and implement it in the " <>
              "higher-level one. The lower context calls through the behaviour, " <>
              "eliminating the direct dependency.",
          applies_when: "One context only needs a callback from the other."
        ),
        Fix.new(
          summary: "Use PubSub for event-driven decoupling",
          detail:
            "Replace direct cross-context calls with PubSub events. The publishing " <>
              "context doesn't need to know about the subscriber.",
          applies_when: "The dependency is for notifications or side effects."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#1.24"],
      context: %{
        cycle: cycle,
        cycle_length: length(cycle)
      },
      file: "lib",
      line: 0
    )
  end
end
