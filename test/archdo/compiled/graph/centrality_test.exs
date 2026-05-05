defmodule Archdo.Compiled.Graph.CentralityTest do
  use ExUnit.Case, async: true

  alias Archdo.Compiled.Graph.Centrality

  describe "page_rank_from/3 — PageRank computation" do
    test "rank values sum to 1.0 (within ε)" do
      # Cycle: A → B → C → A. Sum of ranks always equals 1.0.
      ranks = Centrality.page_rank_from([:a, :b, :c], [{:a, :b}, {:b, :c}, {:c, :a}], [])

      total = ranks |> Map.values() |> Enum.sum()
      assert_in_delta total, 1.0, 1.0e-6
    end

    test "graph with no edges (all isolated) → every node has rank 1/N" do
      # 5-node graph, no edges. All nodes are dangling and have no
      # inbound — under teleportation they each converge to 1/N.
      ranks = Centrality.page_rank_from([:a, :b, :c, :d, :e], [], [])

      assert map_size(ranks) == 5

      Enum.each(ranks, fn {_node, r} ->
        assert_in_delta r, 0.2, 1.0e-6
      end)
    end

    test "highly cited node has higher rank than its citer" do
      # A → B (3 parallel edges). B has incoming, A has only outgoing.
      # B's rank > A's rank under any damping > 0.
      ranks =
        Centrality.page_rank_from([:a, :b], [{:a, :b}, {:a, :b}, {:a, :b}], [])

      assert ranks[:b] > ranks[:a]
    end

    test "converges within max_iterations on a small graph" do
      # Default max 100. On a 4-node strongly-connected graph the
      # algorithm converges in well under 100 iterations — we just
      # need a non-empty result with sum ≈ 1.
      ranks =
        Centrality.page_rank_from(
          [:a, :b, :c, :d],
          [{:a, :b}, {:b, :c}, {:c, :d}, {:d, :a}],
          max_iterations: 100
        )

      total = ranks |> Map.values() |> Enum.sum()
      assert_in_delta total, 1.0, 1.0e-6
      assert map_size(ranks) == 4
    end

    test "damping = 0.0 produces uniform distribution (all ranks = 1/N)" do
      # With no damping (pure teleport), every node converges to 1/N
      # regardless of edge structure.
      ranks =
        Centrality.page_rank_from([:a, :b, :c, :d], [{:a, :b}, {:b, :c}], damping: 0.0)

      Enum.each(ranks, fn {_node, r} ->
        assert_in_delta r, 0.25, 1.0e-6
      end)
    end
  end

  describe "in_degree_from/2 / out_degree_from/2 / total_degree_from/2" do
    # Hand-built 5-node graph:
    #   a → b, a → c, b → c, c → d, c → d (parallel edge), d → e
    # Counts (each occurrence of an edge counts once):
    #   a: in=0, out=2, total=2
    #   b: in=1, out=1, total=2
    #   c: in=2, out=2, total=4
    #   d: in=2, out=1, total=3
    #   e: in=1, out=0, total=1
    @nodes [:a, :b, :c, :d, :e]
    @edges [{:a, :b}, {:a, :c}, {:b, :c}, {:c, :d}, {:c, :d}, {:d, :e}]

    test "in_degree counts incoming edges per node, including parallel edges" do
      in_deg = Centrality.in_degree_from(@nodes, @edges)

      assert in_deg[:a] == 0
      assert in_deg[:b] == 1
      assert in_deg[:c] == 2
      assert in_deg[:d] == 2
      assert in_deg[:e] == 1
    end

    test "out_degree counts outgoing edges per node, including parallel edges" do
      out_deg = Centrality.out_degree_from(@nodes, @edges)

      assert out_deg[:a] == 2
      assert out_deg[:b] == 1
      assert out_deg[:c] == 2
      assert out_deg[:d] == 1
      assert out_deg[:e] == 0
    end

    test "total_degree equals in_degree + out_degree per node" do
      total = Centrality.total_degree_from(@nodes, @edges)

      assert total[:a] == 2
      assert total[:b] == 2
      assert total[:c] == 4
      assert total[:d] == 3
      assert total[:e] == 1
    end
  end

  describe "betweenness_from/3 — Brandes' algorithm" do
    test "5-node directed star: center has betweenness 1.0 (normalized), leaves have 0" do
      # Star: center ↔ each leaf (both directions).
      # All 12 leaf→leaf shortest paths pass through center.
      # Normalized BC(center) = 12 / ((5-1)*(5-2)) = 12/12 = 1.0.
      nodes = [:c, :l1, :l2, :l3, :l4]

      edges =
        for leaf <- [:l1, :l2, :l3, :l4],
            edge <- [{:c, leaf}, {leaf, :c}],
            do: edge

      bc = Centrality.betweenness_from(nodes, edges, [])

      assert_in_delta bc[:c], 1.0, 1.0e-6
      assert_in_delta bc[:l1], 0.0, 1.0e-6
      assert_in_delta bc[:l2], 0.0, 1.0e-6
      assert_in_delta bc[:l3], 0.0, 1.0e-6
      assert_in_delta bc[:l4], 0.0, 1.0e-6
    end

    test "directed chain A→B→C: B is on the only intermediate path, A and C are endpoints" do
      # Only one s→t path traverses an intermediate: A→C through B.
      # Raw BC(B) = 1; normalized = 1 / ((3-1)*(3-2)) = 1/2 = 0.5.
      bc = Centrality.betweenness_from([:a, :b, :c], [{:a, :b}, {:b, :c}], [])

      assert_in_delta bc[:a], 0.0, 1.0e-6
      assert_in_delta bc[:b], 0.5, 1.0e-6
      assert_in_delta bc[:c], 0.0, 1.0e-6
    end

    test "4-node mesh A→{B,C}→D: B and C share the A→D bridge equally; A and D are endpoints" do
      # Edges: A→B, A→C, B→D, C→D.
      # Pair (A,D) has TWO shortest paths (A→B→D, A→C→D); B and C
      # each get half the credit.
      # Raw BC(B) = 0.5, BC(C) = 0.5; A and D are 0.
      # Normalized: divide by (4-1)*(4-2) = 6 → 0.5/6 ≈ 0.0833.
      bc =
        Centrality.betweenness_from(
          [:a, :b, :c, :d],
          [{:a, :b}, {:a, :c}, {:b, :d}, {:c, :d}],
          []
        )

      assert_in_delta bc[:a], 0.0, 1.0e-6
      assert_in_delta bc[:b], 0.5 / 6, 1.0e-6
      assert_in_delta bc[:c], 0.5 / 6, 1.0e-6
      assert_in_delta bc[:d], 0.0, 1.0e-6
    end
  end
end
