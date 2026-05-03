defmodule Archdo.Rules.CE.UnanchoredIsland do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-31. Strongly-connected components of
  # the module graph whose members are not transitively reachable from
  # any anchor. More insidious than CE-30: each individual module
  # looks fine locally — has callers, has callees, is "used" — but the
  # cluster as a whole traces to nothing. The pattern of speculative
  # scaffolding that grew internal connections and never wired up to a
  # real driver.
  #
  # Cluster size is irrelevant: a 2-module mutual reference unanchored
  # is just as dead as a 20-module web. One Diagnostic per cluster
  # (not per module) — the cluster is the unit of diagnosis.

  alias Archdo.{AnchorSet, AST, Diagnostic, Fix, Graph}

  @impl true
  def id, do: "CE-31"

  @impl true
  def description, do: "Unanchored island — mutually-reachable cluster, no anchored caller"

  @doc """
  Project-level analysis. Returns one Diagnostic per cluster.
  """
  @spec analyze_project([{String.t(), Macro.t()}]) :: [Diagnostic.t()]
  def analyze_project(file_asts) do
    production_asts = Enum.reject(file_asts, fn {file, _} -> AST.test_file?(file) end)

    anchors = AnchorSet.compute(production_asts)
    graph = Graph.build(production_asts)
    closure = AnchorSet.closure(anchors, graph)

    file_by_module = AST.module_file_map(production_asts)
    sccs = compute_sccs(graph)

    for scc <- sccs,
        length(scc) >= 2,
        Enum.all?(scc, &(not MapSet.member?(closure, &1))) do
      build_diagnostic(scc, file_by_module)
    end
  end

  # --- module-level Tarjan SCC ---
  # Adapted from compiled/graph.ex's mfa-tuple version. Modules as nodes,
  # forward call edges from Graph.dependencies/2 as adjacency.

  defp compute_sccs(%Graph{} = graph) do
    nodes = MapSet.to_list(graph.modules)

    adjacency =
      Map.new(nodes, fn node ->
        targets =
          graph
          |> Graph.dependencies(node)
          |> Enum.map(& &1.target)
          |> Enum.uniq()

        {node, targets}
      end)

    state = %{
      index: 0,
      indices: %{},
      lowlinks: %{},
      stack: [],
      on_stack: MapSet.new(),
      sccs: []
    }

    final =
      Enum.reduce(nodes, state, fn node, acc ->
        case Map.has_key?(acc.indices, node) do
          true -> acc
          false -> strongconnect(node, adjacency, acc)
        end
      end)

    Map.fetch!(final, :sccs)
  end

  defp strongconnect(v, adjacency, state) do
    state = %{
      state
      | indices: Map.put(state.indices, v, state.index),
        lowlinks: Map.put(state.lowlinks, v, state.index),
        index: state.index + 1,
        stack: [v | state.stack],
        on_stack: MapSet.put(state.on_stack, v)
    }

    state =
      Enum.reduce(Map.get(adjacency, v, []), state, fn w, acc ->
        cond do
          not Map.has_key?(acc.indices, w) ->
            acc = strongconnect(w, adjacency, acc)
            v_low = Map.fetch!(acc.lowlinks, v)
            w_low = Map.fetch!(acc.lowlinks, w)
            %{acc | lowlinks: Map.put(acc.lowlinks, v, min(v_low, w_low))}

          MapSet.member?(acc.on_stack, w) ->
            v_low = Map.fetch!(acc.lowlinks, v)
            w_idx = Map.fetch!(acc.indices, w)
            %{acc | lowlinks: Map.put(acc.lowlinks, v, min(v_low, w_idx))}

          true ->
            acc
        end
      end)

    case Map.fetch!(state.lowlinks, v) == Map.fetch!(state.indices, v) do
      true ->
        {scc, remaining_stack, remaining_on_stack} =
          pop_scc(v, state.stack, state.on_stack, [])

        %{state | stack: remaining_stack, on_stack: remaining_on_stack, sccs: [scc | state.sccs]}

      false ->
        state
    end
  end

  defp pop_scc(v, [v | rest], on_stack, acc) do
    {[v | acc], rest, MapSet.delete(on_stack, v)}
  end

  defp pop_scc(v, [w | rest], on_stack, acc) do
    pop_scc(v, rest, MapSet.delete(on_stack, w), [w | acc])
  end

  # --- diagnostic ---

  defp build_diagnostic(scc, file_by_module) do
    members = Enum.sort(scc)
    primary_file = Map.get(file_by_module, hd(members), "lib/")

    Diagnostic.warning("CE-31",
      title: "Unanchored island — mutually-reachable cluster traces to nothing",
      message:
        "Cluster of #{length(members)} modules — #{Enum.join(members, ", ")} — " <>
          "is mutually-reachable but no member is in any anchor's closure",
      why:
        "More insidious than CE-30 because every individual module looks fine " <>
          "locally — each has callers, each has callees, each is 'used'. The smell " <>
          "only emerges when you ask 'but who uses any of you, ultimately?' Often " <>
          "leftover from exploration, a removed feature, or speculative scaffolding " <>
          "that never connected to the real system.",
      alternatives: [
        Fix.new(
          summary: "Delete the cluster",
          detail:
            "If the cluster represents a feature that was built but never wired up, " <>
              "remove all the modules.",
          applies_when: "The feature was abandoned or superseded."
        ),
        Fix.new(
          summary: "Wire the cluster to an anchor",
          detail:
            "If the cluster represents a real feature that lacks a route, job, or task, " <>
              "add the missing entry point. Or mark one member with " <>
              "`@archdo_anchor \"<reason>\"` if the entry path is dynamic.",
          applies_when: "The feature is real but not yet wired up."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-31"],
      context: %{cluster_members: members, cluster_size: length(members)},
      file: primary_file,
      line: 1
    )
  end
end
