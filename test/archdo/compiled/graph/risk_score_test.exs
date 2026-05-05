defmodule Archdo.Compiled.Graph.RiskScoreTest do
  use ExUnit.Case, async: true

  alias Archdo.Compiled.Graph.RiskScore

  describe "compute_from/2" do
    test "high PageRank AND high complexity scores higher than either signal alone" do
      inputs = %{
        :both_high => %{pagerank: 0.8, complexity: 0.8, halstead: 0.5, coupling: 0.5},
        :pr_only => %{pagerank: 0.8, complexity: 0.1, halstead: 0.5, coupling: 0.5},
        :cx_only => %{pagerank: 0.1, complexity: 0.8, halstead: 0.5, coupling: 0.5}
      }

      scores = RiskScore.compute_from(inputs)

      assert scores[:both_high] > scores[:pr_only]
      assert scores[:both_high] > scores[:cx_only]
    end

    test "isolated leaf with all-zero inputs has near-zero risk" do
      inputs = %{
        :leaf => %{pagerank: 0.0, complexity: 0.0, halstead: 0.0, coupling: 0.0}
      }

      scores = RiskScore.compute_from(inputs)

      assert scores[:leaf] == 0.0
    end

    test "weights sum to 1.0 (sanity); all-uniform 0.5 inputs produce 0.5 score" do
      assert_in_delta Enum.sum(Map.values(RiskScore.weights())), 1.0, 1.0e-9

      inputs = %{
        :uniform => %{pagerank: 0.5, complexity: 0.5, halstead: 0.5, coupling: 0.5}
      }

      scores = RiskScore.compute_from(inputs)

      assert_in_delta scores[:uniform], 0.5, 1.0e-6
    end
  end
end
