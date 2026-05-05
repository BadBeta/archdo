defmodule Archdo.Compiled.Graph.Centrality do
  @moduledoc """
  Centrality metrics on the compiled call graph. Currently exposes
  PageRank; degree / betweenness / closeness land in M5–M7 of the
  Ragex-adoption milestone plan.

  Two entry points:

  - `page_rank/2` — takes an `Archdo.Compiled.Graph.t()` and computes
    PageRank over its call edges. Nodes are the union of all caller
    and callee MFAs plus every module's exports (so isolated functions
    contribute to the rank distribution).
  - `page_rank_from/3` — takes an explicit node enumerable and edge
    list. Used by tests and by callers that already have inputs in
    that shape.

  The algorithm is standard iterative PageRank with explicit dangling-
  node redistribution: dangling rank is shared equally across all
  nodes via teleportation, so the rank vector remains a probability
  distribution (sums to 1) at every iteration.
  """

  Module.register_attribute(__MODULE__, :archdo_volatility, persist: true)
  @archdo_volatility :stable

  alias Archdo.Compiled.Graph

  @default_damping 0.85
  @default_max_iter 100
  @default_epsilon 1.0e-6

  @type node_id :: any()
  @type rank_map :: %{node_id() => float()}

  @doc """
  Compute PageRank for every node in a `Compiled.Graph`. Edges come
  from `Graph.calls/1`; nodes are the union of every MFA appearing as
  caller or callee, plus every module export from `Graph.modules/1`.
  """
  @spec page_rank(Graph.t(), keyword()) :: rank_map()
  def page_rank(graph, opts \\ []) do
    page_rank_from(collect_nodes(graph), graph_edges(graph), opts)
  end

  @doc """
  Compute PageRank from an explicit node enumerable and edge list.

  Options:
    * `:damping` — float in [0, 1], default 0.85.
    * `:max_iterations` — positive integer, default 100.
    * `:epsilon` — convergence threshold for the L1 delta between
      successive rank vectors, default 1.0e-6.
  """
  @spec page_rank_from(Enumerable.t(), [{node_id(), node_id()}], keyword()) :: rank_map()
  def page_rank_from(nodes, edges, opts \\ []) do
    node_set = MapSet.new(nodes)
    n = MapSet.size(node_set)

    case n do
      0 -> %{}
      _ -> run(node_set, edges, n, opts)
    end
  end

  @doc """
  In-degree per node — count of incoming edges (including parallel
  edges). Reads edges from the graph's call list.
  """
  @spec in_degree(Graph.t()) :: %{node_id() => non_neg_integer()}
  def in_degree(graph) do
    edges = graph_edges(graph)
    in_degree_from(collect_nodes(graph), edges)
  end

  @doc """
  Out-degree per node — count of outgoing edges (including parallel
  edges).
  """
  @spec out_degree(Graph.t()) :: %{node_id() => non_neg_integer()}
  def out_degree(graph) do
    edges = graph_edges(graph)
    out_degree_from(collect_nodes(graph), edges)
  end

  @doc """
  Total degree per node — `in_degree + out_degree`.
  """
  @spec total_degree(Graph.t()) :: %{node_id() => non_neg_integer()}
  def total_degree(graph) do
    edges = graph_edges(graph)
    total_degree_from(collect_nodes(graph), edges)
  end

  @doc "In-degree from explicit nodes + edges. Test-friendly companion."
  @spec in_degree_from(Enumerable.t(), [{node_id(), node_id()}]) ::
          %{node_id() => non_neg_integer()}
  def in_degree_from(nodes, edges), do: degree_count(nodes, edges, :dst)

  @doc "Out-degree from explicit nodes + edges. Test-friendly companion."
  @spec out_degree_from(Enumerable.t(), [{node_id(), node_id()}]) ::
          %{node_id() => non_neg_integer()}
  def out_degree_from(nodes, edges), do: degree_count(nodes, edges, :src)

  defp degree_count(nodes, edges, end_kind) do
    initial = Map.new(nodes, fn v -> {v, 0} end)

    Enum.reduce(edges, initial, fn edge, acc ->
      Map.update(acc, edge_end(edge, end_kind), 1, &(&1 + 1))
    end)
  end

  defp edge_end({src, _dst}, :src), do: src
  defp edge_end({_src, dst}, :dst), do: dst

  @doc "Total degree from explicit nodes + edges (in + out)."
  @spec total_degree_from(Enumerable.t(), [{node_id(), node_id()}]) ::
          %{node_id() => non_neg_integer()}
  def total_degree_from(nodes, edges) do
    in_deg = in_degree_from(nodes, edges)
    out_deg = out_degree_from(nodes, edges)
    Map.new(in_deg, fn {v, in_count} -> {v, in_count + Map.get(out_deg, v, 0)} end)
  end

  defp graph_edges(graph), do: Enum.map(Graph.calls(graph), fn c -> {c.caller, c.callee} end)

  # --- Betweenness (Brandes 2001) ---

  @doc """
  Betweenness centrality on the call graph. Identifies bridge /
  bottleneck functions — those that lie on many shortest paths between
  other functions. Brandes' single-source-shortest-path algorithm.

  Options:
    * `:normalized` — divide raw counts by `(n-1)*(n-2)` (directed
      normalization). Default `true`.
  """
  @spec betweenness(Graph.t(), keyword()) :: %{node_id() => float()}
  def betweenness(graph, opts \\ []) do
    betweenness_from(collect_nodes(graph), graph_edges(graph), opts)
  end

  @doc """
  Betweenness from explicit nodes + edges. Test-friendly companion.
  """
  @spec betweenness_from(Enumerable.t(), [{node_id(), node_id()}], keyword()) ::
          %{node_id() => float()}
  def betweenness_from(nodes, edges, opts \\ []) do
    node_set = MapSet.new(nodes)
    n = MapSet.size(node_set)

    case n < 3 do
      true -> Map.new(node_set, fn v -> {v, 0.0} end)
      false -> compute_betweenness(node_set, edges, n, opts)
    end
  end

  defp compute_betweenness(node_set, edges, n, opts) do
    successors = Enum.group_by(edges, fn {src, _} -> src end, fn {_, dst} -> dst end)
    initial = Map.new(node_set, fn v -> {v, 0.0} end)

    raw =
      Enum.reduce(node_set, initial, fn s, bc ->
        accumulate_from_source(s, node_set, successors, bc)
      end)

    case Keyword.get(opts, :normalized, true) do
      true -> normalize_betweenness(raw, n)
      false -> raw
    end
  end

  defp accumulate_from_source(source, nodes, successors, bc) do
    %{stack: stack, predecessors: preds, sigma: sigma} =
      brandes_bfs(source, nodes, successors)

    delta = Map.new(nodes, fn v -> {v, 0.0} end)

    {_final_delta, final_bc} =
      Enum.reduce(stack, {delta, bc}, fn w, {d, bc_acc} ->
        accumulate_dependency(w, source, preds, sigma, d, bc_acc)
      end)

    final_bc
  end

  defp accumulate_dependency(w, source, preds, sigma, d, bc) do
    d_w = Map.get(d, w)
    sigma_w = Map.get(sigma, w)

    d_updated =
      Enum.reduce(Map.get(preds, w, []), d, fn v, d_acc ->
        contribution = Map.get(sigma, v) / sigma_w * (1.0 + d_w)
        Map.update!(d_acc, v, &(&1 + contribution))
      end)

    bc_updated =
      case w == source do
        true -> bc
        false -> Map.update!(bc, w, &(&1 + d_w))
      end

    {d_updated, bc_updated}
  end

  # BFS from `source`. Returns the discovery stack (most-recent-first
  # for reverse-iteration during dependency accumulation), the
  # predecessor sets on shortest paths, and the path counts σ.
  defp brandes_bfs(source, nodes, successors) do
    distance = Map.put(Map.new(nodes, fn v -> {v, -1} end), source, 0)
    sigma = Map.put(Map.new(nodes, fn v -> {v, 0} end), source, 1)

    state = %{
      queue: :queue.in(source, :queue.new()),
      distance: distance,
      sigma: sigma,
      predecessors: %{},
      stack: []
    }

    bfs_loop(state, successors)
  end

  defp bfs_loop(state, successors) do
    case :queue.out(state.queue) do
      {{:value, v}, q} ->
        state = %{state | queue: q, stack: [v | state.stack]}
        next = Enum.reduce(Map.get(successors, v, []), state, &visit_neighbor(v, &1, &2))
        bfs_loop(next, successors)

      {:empty, _} ->
        state
    end
  end

  defp visit_neighbor(v, w, state) do
    state
    |> maybe_enqueue_unseen(v, w)
    |> maybe_count_path(v, w)
  end

  defp maybe_enqueue_unseen(state, v, w) do
    case Map.get(state.distance, w) do
      -1 ->
        %{
          state
          | distance: Map.put(state.distance, w, Map.get(state.distance, v) + 1),
            queue: :queue.in(w, state.queue)
        }

      _ ->
        state
    end
  end

  defp maybe_count_path(state, v, w) do
    case Map.get(state.distance, w) == Map.get(state.distance, v) + 1 do
      true ->
        %{
          state
          | sigma: Map.update!(state.sigma, w, &(&1 + Map.get(state.sigma, v))),
            predecessors: Map.update(state.predecessors, w, [v], &[v | &1])
        }

      false ->
        state
    end
  end

  defp normalize_betweenness(raw, n) do
    factor = (n - 1) * (n - 2)
    Map.new(raw, fn {v, val} -> {v, val / factor} end)
  end

  # --- Algorithm ---

  defp run(node_set, edges, n, opts) do
    damping = Keyword.get(opts, :damping, @default_damping)
    max_iter = Keyword.get(opts, :max_iterations, @default_max_iter)
    epsilon = Keyword.get(opts, :epsilon, @default_epsilon)

    initial = Map.new(node_set, fn v -> {v, 1.0 / n} end)

    out_edges = Enum.group_by(edges, fn {src, _} -> src end, fn {_, dst} -> dst end)
    out_degree = Map.new(out_edges, fn {src, dsts} -> {src, length(dsts)} end)
    inbound = build_inbound(edges, out_degree)
    dangling = MapSet.difference(node_set, MapSet.new(Map.keys(out_edges)))

    iterate(initial, inbound, dangling, n, damping, max_iter, epsilon)
  end

  defp build_inbound(edges, out_degree) do
    Enum.reduce(edges, %{}, fn {src, dst}, acc ->
      contribution = 1.0 / Map.fetch!(out_degree, src)
      Map.update(acc, dst, [{src, contribution}], &[{src, contribution} | &1])
    end)
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatches on the
  # iteration-count exhaustion case (no if/else in the loop body).
  defp iterate(rank, _inbound, _dangling, _n, _d, 0, _eps), do: rank

  defp iterate(rank, inbound, dangling, n, damping, iter_left, epsilon) do
    dangling_sum =
      Enum.reduce(dangling, 0.0, fn v, acc -> acc + Map.get(rank, v, 0.0) end)

    teleport = (1.0 - damping) / n + damping * dangling_sum / n

    new_rank =
      Map.new(rank, fn {v, _old} ->
        contrib =
          Enum.reduce(Map.get(inbound, v, []), 0.0, fn {src, weight}, acc ->
            acc + Map.get(rank, src, 0.0) * weight
          end)

        {v, teleport + damping * contrib}
      end)

    delta =
      Enum.reduce(rank, 0.0, fn {v, old}, acc ->
        acc + abs(old - Map.get(new_rank, v, 0.0))
      end)

    case delta < epsilon do
      true -> new_rank
      false -> iterate(new_rank, inbound, dangling, n, damping, iter_left - 1, epsilon)
    end
  end

  # Union of every node referenced by an edge plus every module export.
  # Including exports ensures isolated functions (no calls in or out)
  # appear in the rank vector.
  defp collect_nodes(graph) do
    from_calls =
      graph
      |> Graph.calls()
      |> Enum.flat_map(fn c -> [c.caller, c.callee] end)

    from_exports =
      graph
      |> Graph.modules()
      |> Enum.flat_map(fn {mod, info} ->
        Enum.map(info.exports, fn {f, a} -> {mod, f, a} end)
      end)

    MapSet.new(from_calls ++ from_exports)
  end
end
