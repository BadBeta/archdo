defmodule Archdo.Rules.Boundary.ContextDriftTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Boundary.ContextDrift

  describe "compute_drift/3" do
    test "fires when module's community differs from its context's modal AND module has many outgoing edges" do
      contexts = [
        %{context: "MyApp.Catalog", members: [Catalog.A, Catalog.B, Catalog.Drifter]}
      ]

      # Catalog.A and Catalog.B in community 1; Catalog.Drifter in
      # community 2. Modal for Catalog = community 1.
      module_communities = %{
        Catalog.A => 1,
        Catalog.B => 1,
        Catalog.Drifter => 2
      }

      # Drifter has 10 outgoing edges (above @min_outgoing=5).
      outgoing = %{Catalog.A => 1, Catalog.B => 1, Catalog.Drifter => 10}

      findings = ContextDrift.compute_drift(contexts, module_communities, outgoing)

      assert length(findings) == 1
      diag = hd(findings)
      assert diag.rule_id == "1.34"
      assert diag.severity == :info
      assert inspect(diag.context.module) =~ "Catalog.Drifter"
    end

    test "does NOT fire when the drifting module has too few outgoing edges (community signal too noisy)" do
      contexts = [
        %{context: "MyApp.Catalog", members: [Catalog.A, Catalog.B, Catalog.Tiny]}
      ]

      module_communities = %{
        Catalog.A => 1,
        Catalog.B => 1,
        Catalog.Tiny => 2
      }

      # Tiny has only 2 outgoing edges (below the min-outgoing threshold).
      outgoing = %{Catalog.A => 1, Catalog.B => 1, Catalog.Tiny => 2}

      findings = ContextDrift.compute_drift(contexts, module_communities, outgoing)

      assert findings == []
    end
  end
end
