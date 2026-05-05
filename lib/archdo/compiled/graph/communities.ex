defmodule Archdo.Compiled.Graph.Communities do
  @moduledoc """
  Community detection on the compiled call graph. Currently exposes
  label-propagation; Louvain modularity optimization is planned for a
  future iteration.

  Label propagation iteratively assigns each node the most-frequent
  label among its (undirected) neighbors. Cheap, fast, deterministic
  enough for offline analysis when seeded from initial labels =
  node-id. Stable usually after 5-10 passes on graphs of any
  practical size.
  """

  Module.register_attribute(__MODULE__, :archdo_volatility, persist: true)
  @archdo_volatility :stable

  alias Archdo.Compiled.Graph

  @default_max_iterations 100

  @type node_id :: any()
  @type label_map :: %{node_id() => any()}

  @doc """
  Label-propagation community detection on a `Compiled.Graph`.
  Returns `%{node => community-id}`. Treats edges as undirected for
  the purpose of finding communities (an `A → B` call counts toward
  both A's neighbor set and B's).
  """
  @spec label_propagation(Graph.t(), keyword()) :: label_map()
  def label_propagation(graph, opts \\ []) do
    edges = Enum.map(Graph.calls(graph), fn c -> {c.caller, c.callee} end)
    nodes = Graph.all_nodes(graph)
    label_propagation_from(nodes, edges, opts)
  end

  @doc """
  Label propagation from explicit nodes + edges. Test-friendly
  companion. Edges are treated as undirected — neighbors are the
  union of in- and out-edges.
  """
  @spec label_propagation_from(Enumerable.t(), [{node_id(), node_id()}], keyword()) ::
          label_map()
  def label_propagation_from(nodes, edges, opts \\ []) do
    node_set = MapSet.new(nodes)
    max_iter = Keyword.get(opts, :max_iterations, @default_max_iterations)

    case MapSet.size(node_set) do
      0 -> %{}
      _ -> run(node_set, edges, max_iter)
    end
  end

  defp run(node_set, edges, max_iter) do
    neighbors = build_undirected_neighbors(edges)
    initial = Map.new(node_set, fn v -> {v, v} end)
    iterate(initial, neighbors, MapSet.to_list(node_set), max_iter)
  end

  defp build_undirected_neighbors(edges) do
    Enum.reduce(edges, %{}, fn {a, b}, acc ->
      acc
      |> Map.update(a, [b], &[b | &1])
      |> Map.update(b, [a], &[a | &1])
    end)
  end

  # Asynchronous label propagation: each pass updates nodes in turn,
  # immediately reusing the new label for subsequent updates within
  # the same pass. Converges (no oscillation) on graphs with clear
  # community structure. Has a known limitation: on barbell-style
  # graphs (two cliques joined by a single bridge edge), the bridge
  # can propagate labels across; better separation requires Louvain.
  defp iterate(labels, _neighbors, _node_order, 0), do: labels

  defp iterate(labels, neighbors, node_order, iter_left) do
    new_labels =
      Enum.reduce(node_order, labels, fn v, acc ->
        Map.put(acc, v, majority_label(v, neighbors, acc))
      end)

    case new_labels == labels do
      true -> new_labels
      false -> iterate(new_labels, neighbors, node_order, iter_left - 1)
    end
  end

  defp majority_label(v, neighbors, labels) do
    nbrs = Map.get(neighbors, v, [])

    case nbrs do
      [] ->
        Map.get(labels, v)

      _ ->
        nbrs
        |> Enum.frequencies_by(fn n -> Map.get(labels, n) end)
        |> Enum.max_by(fn {_, count} -> count end)
        |> elem(0)
    end
  end

end
