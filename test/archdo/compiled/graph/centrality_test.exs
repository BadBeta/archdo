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
end
