defmodule Archdo.Compiled.Graph.CommunitiesTest do
  use ExUnit.Case, async: true

  alias Archdo.Compiled.Graph.Communities

  describe "label_propagation_from/3" do
    test "two fully-disjoint 4-cliques → 2 distinct communities" do
      # No bridge: cliques A and B share no edges. Label propagation
      # reliably finds two communities here. Adding a single bridge
      # is a known LP limitation — strict community separation across
      # narrow bridges requires Louvain modularity (future work).
      a_nodes = ~w(a1 a2 a3 a4)a
      b_nodes = ~w(b1 b2 b3 b4)a
      nodes = a_nodes ++ b_nodes

      clique1 = for x <- a_nodes, y <- a_nodes, x != y, do: {x, y}
      clique2 = for x <- b_nodes, y <- b_nodes, x != y, do: {x, y}

      labels =
        Communities.label_propagation_from(nodes, clique1 ++ clique2, max_iterations: 100)

      a_labels = a_nodes |> Enum.map(&labels[&1]) |> Enum.uniq()
      b_labels = b_nodes |> Enum.map(&labels[&1]) |> Enum.uniq()

      assert length(a_labels) == 1
      assert length(b_labels) == 1
      assert hd(a_labels) != hd(b_labels)
    end

    test "tight clique: every node converges to one community" do
      # Triangle — each node sees both others as neighbors.
      nodes = [:a, :b, :c]
      edges = [{:a, :b}, {:b, :a}, {:b, :c}, {:c, :b}, {:a, :c}, {:c, :a}]

      labels = Communities.label_propagation_from(nodes, edges, max_iterations: 100)

      assert labels[:a] == labels[:b]
      assert labels[:b] == labels[:c]
    end

    test "two disconnected components stay in separate communities" do
      # No edges between {a, b} and {c, d}.
      nodes = [:a, :b, :c, :d]
      edges = [{:a, :b}, {:b, :a}, {:c, :d}, {:d, :c}]

      labels = Communities.label_propagation_from(nodes, edges, max_iterations: 100)

      assert labels[:a] == labels[:b]
      assert labels[:c] == labels[:d]
      assert labels[:a] != labels[:c]
    end
  end
end
