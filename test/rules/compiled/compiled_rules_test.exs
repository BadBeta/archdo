defmodule Archdo.Rules.Compiled.CompiledRulesTest do
  use ExUnit.Case, async: true

  @moduletag :self_analysis

  alias Archdo.Compiled.Graph
  alias Archdo.Rules.Compiled.{
    DeadCode,
    TransitiveDeadCode,
    UnusedImports,
    CompileDependencyHotspot,
    WeakDependency,
    TestOnlyPublic,
    ApiSurfaceWeight,
    CircularFunctionCalls,
    ProtocolCompleteness,
    ChangeRisk,
    NonExhaustiveApi,
    InconsistentApiReturn,
    CrossBoundaryCall,
    InternalModuleLeak,
    PhantomDependency,
    RepoBypass,
    DegenerateFunction,
    LookupTableCandidate,
    ContextQuality,
    CircularContextDeps,
    OrphanModule
  }

  setup_all do
    beam_dir = Path.join([File.cwd!(), "_build", "test", "lib", "archdo", "ebin"])
    graph = Graph.build(beam_dir)
    %{graph: graph}
  end

  # --- Rule metadata ---

  describe "rule metadata" do
    test "DeadCode has correct id and description" do
      assert DeadCode.id() == "6.24"
      assert is_binary(DeadCode.description())
    end

    test "TransitiveDeadCode has correct id" do
      assert TransitiveDeadCode.id() == "6.25"
    end

    test "UnusedImports has correct id" do
      assert UnusedImports.id() == "4.22"
    end

    test "CompileDependencyHotspot has correct id" do
      assert CompileDependencyHotspot.id() == "1.18"
    end

    test "WeakDependency has correct id" do
      assert WeakDependency.id() == "4.23"
    end

    test "TestOnlyPublic has correct id" do
      assert TestOnlyPublic.id() == "7.21"
    end

    test "ApiSurfaceWeight has correct id" do
      assert ApiSurfaceWeight.id() == "6.26"
    end

    test "CircularFunctionCalls has correct id" do
      assert CircularFunctionCalls.id() == "1.19"
    end

    test "ProtocolCompleteness has correct id" do
      assert ProtocolCompleteness.id() == "4.24"
    end

    test "ChangeRisk has correct id" do
      assert ChangeRisk.id() == "1.20"
    end

    test "NonExhaustiveApi has correct id" do
      assert NonExhaustiveApi.id() == "6.27"
    end

    test "InconsistentApiReturn has correct id" do
      assert InconsistentApiReturn.id() == "6.28"
    end

    test "CrossBoundaryCall has correct id" do
      assert CrossBoundaryCall.id() == "1.21"
    end

    test "InternalModuleLeak has correct id" do
      assert InternalModuleLeak.id() == "4.25"
    end

    test "PhantomDependency has correct id" do
      assert PhantomDependency.id() == "4.26"
    end

    test "RepoBypass has correct id" do
      assert RepoBypass.id() == "1.22"
    end

    test "DegenerateFunction has correct id" do
      assert DegenerateFunction.id() == "6.30"
    end

    test "LookupTableCandidate has correct id" do
      assert LookupTableCandidate.id() == "6.31"
    end

    test "ContextQuality has correct id" do
      assert ContextQuality.id() == "1.23"
    end

    test "CircularContextDeps has correct id" do
      assert CircularContextDeps.id() == "1.24"
    end

    test "OrphanModule has correct id" do
      assert OrphanModule.id() == "1.25"
    end
  end

  # --- AST mode returns empty ---

  describe "AST-mode analyze/3 returns empty" do
    test "all compiled rules return [] for AST analysis" do
      rules = [
        DeadCode,
        TransitiveDeadCode,
        UnusedImports,
        CompileDependencyHotspot,
        WeakDependency,
        TestOnlyPublic,
        ApiSurfaceWeight,
        CircularFunctionCalls,
        ProtocolCompleteness,
        ChangeRisk,
        NonExhaustiveApi,
        InconsistentApiReturn,
        CrossBoundaryCall,
        InternalModuleLeak,
        PhantomDependency,
        RepoBypass,
        DegenerateFunction,
        LookupTableCandidate,
        ContextQuality,
        CircularContextDeps,
        OrphanModule
      ]

      Enum.each(rules, fn rule ->
        assert rule.analyze("lib/test.ex", {:defmodule, [], []}, []) == [],
               "#{inspect(rule)}.analyze/3 should return [] in AST mode"
      end)
    end
  end

  # --- DeadCode (6.24) ---

  describe "DeadCode (6.24)" do
    test "finds dead public functions in Archdo", %{graph: graph} do
      diagnostics = DeadCode.analyze_compiled(graph)
      assert length(diagnostics) > 0
      assert Enum.all?(diagnostics, &(&1.rule_id == "6.24"))
    end

    test "diagnostics have expected structure", %{graph: graph} do
      [diag | _] = DeadCode.analyze_compiled(graph)
      assert diag.title == "Dead public function"
      assert is_binary(diag.message)
      assert diag.severity == :info
    end
  end

  # --- TransitiveDeadCode (6.25) ---

  describe "TransitiveDeadCode (6.25)" do
    test "finds transitively dead functions", %{graph: graph} do
      diagnostics = TransitiveDeadCode.analyze_compiled(graph)
      assert is_list(diagnostics)
      assert Enum.all?(diagnostics, &(&1.rule_id == "6.25"))
    end

    test "does not include stdlib functions", %{graph: graph} do
      diagnostics = TransitiveDeadCode.analyze_compiled(graph)

      Enum.each(diagnostics, fn diag ->
        refute String.starts_with?(diag.message, "Enum."),
               "Should not flag stdlib: #{diag.message}"

        refute String.starts_with?(diag.message, "IO."),
               "Should not flag stdlib: #{diag.message}"
      end)
    end
  end

  # --- UnusedImports (4.22) ---

  describe "UnusedImports (4.22)" do
    test "finds modules with low import utilization", %{graph: graph} do
      diagnostics = UnusedImports.analyze_compiled(graph)
      assert is_list(diagnostics)
      assert Enum.all?(diagnostics, &(&1.rule_id == "4.22"))
    end

    test "diagnostics mention usage percentage", %{graph: graph} do
      diagnostics = UnusedImports.analyze_compiled(graph)

      case diagnostics do
        [] -> :ok
        [diag | _] -> assert diag.message =~ "%"
      end
    end
  end

  # --- CompileDependencyHotspot (1.18) ---

  describe "CompileDependencyHotspot (1.18)" do
    test "flags modules with many dependents", %{graph: graph} do
      diagnostics = CompileDependencyHotspot.analyze_compiled(graph)
      assert length(diagnostics) > 0
      assert Enum.all?(diagnostics, &(&1.rule_id == "1.18"))
    end

    test "Archdo.AST should be a hotspot", %{graph: graph} do
      diagnostics = CompileDependencyHotspot.analyze_compiled(graph)
      messages = Enum.map(diagnostics, & &1.message)
      assert Enum.any?(messages, &(&1 =~ "Archdo.AST"))
    end
  end

  # --- WeakDependency (4.23) ---

  describe "WeakDependency (4.23)" do
    test "finds weak dependencies", %{graph: graph} do
      diagnostics = WeakDependency.analyze_compiled(graph)
      assert is_list(diagnostics)
      assert Enum.all?(diagnostics, &(&1.rule_id == "4.23"))
    end

    test "diagnostics list the specific functions used", %{graph: graph} do
      diagnostics = WeakDependency.analyze_compiled(graph)

      case diagnostics do
        [] -> :ok
        [diag | _] -> assert diag.message =~ "/"
      end
    end
  end

  # --- TestOnlyPublic (7.21) ---

  describe "TestOnlyPublic (7.21)" do
    test "returns diagnostics list", %{graph: graph} do
      diagnostics = TestOnlyPublic.analyze_compiled(graph)
      assert is_list(diagnostics)
      assert Enum.all?(diagnostics, &(&1.rule_id == "7.21"))
    end
  end

  # --- ApiSurfaceWeight (6.26) ---

  describe "ApiSurfaceWeight (6.26)" do
    test "flags modules with oversized API", %{graph: graph} do
      diagnostics = ApiSurfaceWeight.analyze_compiled(graph)
      assert is_list(diagnostics)
      assert Enum.all?(diagnostics, &(&1.rule_id == "6.26"))
    end

    test "diagnostics mention percentage", %{graph: graph} do
      diagnostics = ApiSurfaceWeight.analyze_compiled(graph)

      case diagnostics do
        [] -> :ok
        [diag | _] -> assert diag.message =~ "%"
      end
    end
  end

  # --- CircularFunctionCalls (1.19) ---

  describe "CircularFunctionCalls (1.19)" do
    test "returns diagnostics list", %{graph: graph} do
      diagnostics = CircularFunctionCalls.analyze_compiled(graph)
      assert is_list(diagnostics)
      assert Enum.all?(diagnostics, &(&1.rule_id == "1.19"))
    end
  end

  # --- ProtocolCompleteness (4.24) ---

  describe "ProtocolCompleteness (4.24)" do
    test "returns diagnostics list", %{graph: graph} do
      diagnostics = ProtocolCompleteness.analyze_compiled(graph)
      assert is_list(diagnostics)
      assert Enum.all?(diagnostics, &(&1.rule_id == "4.24"))
    end
  end

  # --- ChangeRisk (1.20) ---

  describe "ChangeRisk (1.20)" do
    test "flags high blast radius modules", %{graph: graph} do
      diagnostics = ChangeRisk.analyze_compiled(graph)
      assert length(diagnostics) > 0
      assert Enum.all?(diagnostics, &(&1.rule_id == "1.20"))
    end

    test "Archdo.AST has high blast radius", %{graph: graph} do
      diagnostics = ChangeRisk.analyze_compiled(graph)
      messages = Enum.map(diagnostics, & &1.message)
      assert Enum.any?(messages, &(&1 =~ "Archdo.AST"))
    end

    test "diagnostics include risk score", %{graph: graph} do
      [diag | _] = ChangeRisk.analyze_compiled(graph)
      assert diag.message =~ "risk score"
      assert diag.context.risk_score > 0
    end
  end

  # --- NonExhaustiveApi (6.27) ---

  describe "NonExhaustiveApi (6.27)" do
    test "finds non-exhaustive public functions", %{graph: graph} do
      diagnostics = NonExhaustiveApi.analyze_compiled(graph)
      assert length(diagnostics) > 0
      assert Enum.all?(diagnostics, &(&1.rule_id == "6.27"))
    end

    test "diagnostics include clause count", %{graph: graph} do
      [diag | _] = NonExhaustiveApi.analyze_compiled(graph)
      assert diag.context.clause_count >= 2
    end

    test "does not flag single-clause functions", %{graph: graph} do
      diagnostics = NonExhaustiveApi.analyze_compiled(graph)

      Enum.each(diagnostics, fn diag ->
        assert diag.context.clause_count >= 2
      end)
    end
  end

  # --- InconsistentApiReturn (6.28) ---

  describe "InconsistentApiReturn (6.28)" do
    test "returns diagnostics list", %{graph: graph} do
      diagnostics = InconsistentApiReturn.analyze_compiled(graph)
      assert is_list(diagnostics)
      assert Enum.all?(diagnostics, &(&1.rule_id == "6.28"))
    end

    test "does not flag consistent ok/error functions", %{graph: graph} do
      diagnostics = InconsistentApiReturn.analyze_compiled(graph)

      # Archdo.Compiled.analyze/1 returns {:ok, _} | {:error, _} — should NOT be flagged
      refute Enum.any?(diagnostics, fn diag ->
        diag.context.module == "Archdo.Compiled" and
          diag.context.function == "analyze/1"
      end)
    end
  end

  # --- Graph blast_radius/2 ---

  describe "Graph.blast_radius/2" do
    test "computes blast radius for a module", %{graph: graph} do
      report = Graph.blast_radius(graph, Archdo.AST)
      assert report.module == Archdo.AST
      assert report.total_affected > 10
      assert report.max_depth > 0
      assert is_float(report.risk_score)
      assert is_list(report.direct_dependents)
    end

    test "transitive dependents are grouped by depth", %{graph: graph} do
      report = Graph.blast_radius(graph, Archdo.AST)

      Enum.each(report.transitive_dependents, fn {depth, mods} ->
        assert is_integer(depth)
        assert depth > 0
        assert is_list(mods)
        assert length(mods) > 0
      end)
    end
  end

  # --- Graph.extract_function_clauses/1 ---

  describe "Graph.extract_function_clauses/1" do
    test "extracts clause info from beam files", %{graph: graph} do
      clauses_map = Graph.extract_function_clauses(graph.beam_dir)
      assert is_map(clauses_map)
      assert map_size(clauses_map) > 0

      # Check a known multi-clause function
      diag_fns = Map.get(clauses_map, Archdo.Diagnostic, [])
      builder = Enum.find(diag_fns, fn f -> f.name == :builder_for and f.arity == 1 end)
      assert builder != nil
      assert builder.exported == true
      assert builder.clause_count == 3
      assert builder.has_catch_all == false
    end

    test "classifies return shapes", %{graph: graph} do
      clauses_map = Graph.extract_function_clauses(graph.beam_dir)
      diag_fns = Map.get(clauses_map, Archdo.Diagnostic, [])
      builder = Enum.find(diag_fns, fn f -> f.name == :builder_for and f.arity == 1 end)

      Enum.each(builder.clauses, fn clause ->
        assert clause.return_shape != nil
      end)
    end
  end

  # --- CrossBoundaryCall (1.21) ---

  describe "CrossBoundaryCall (1.21)" do
    test "returns diagnostics list", %{graph: graph} do
      diagnostics = CrossBoundaryCall.analyze_compiled(graph)
      assert is_list(diagnostics)
      # Archdo has no Phoenix contexts, so may be empty
      assert Enum.all?(diagnostics, &(&1.rule_id == "1.21"))
    end
  end

  # --- InternalModuleLeak (4.25) ---

  describe "InternalModuleLeak (4.25)" do
    test "finds internal modules accessed from outside", %{graph: graph} do
      diagnostics = InternalModuleLeak.analyze_compiled(graph)
      assert is_list(diagnostics)
      assert Enum.all?(diagnostics, &(&1.rule_id == "4.25"))
    end

    test "diagnostics identify caller and internal module", %{graph: graph} do
      diagnostics = InternalModuleLeak.analyze_compiled(graph)

      case diagnostics do
        [] ->
          :ok

        [diag | _] ->
          assert is_binary(diag.context.caller)
          assert is_binary(diag.context.internal_module)
          assert is_binary(diag.context.parent)
          assert diag.context.call_count > 0
      end
    end

    test "does not flag widely-used modules like AST and Diagnostic", %{graph: graph} do
      diagnostics = InternalModuleLeak.analyze_compiled(graph)

      refute Enum.any?(diagnostics, fn diag ->
        diag.context.internal_module == "Archdo.AST"
      end), "Archdo.AST is widely used — should not be flagged as internal leak"

      refute Enum.any?(diagnostics, fn diag ->
        diag.context.internal_module == "Archdo.Diagnostic"
      end), "Archdo.Diagnostic is widely used — should not be flagged as internal leak"
    end
  end

  # --- PhantomDependency (4.26) ---

  describe "PhantomDependency (4.26)" do
    test "finds phantom dependencies", %{graph: graph} do
      diagnostics = PhantomDependency.analyze_compiled(graph)
      assert is_list(diagnostics)
      assert length(diagnostics) > 0
      assert Enum.all?(diagnostics, &(&1.rule_id == "4.26"))
    end

    test "detects struct-only references", %{graph: graph} do
      diagnostics = PhantomDependency.analyze_compiled(graph)

      struct_phantoms =
        Enum.filter(diagnostics, fn diag ->
          diag.context.reference_type == :struct
        end)

      # Formatter references %Diagnostic{} struct but doesn't call Diagnostic functions
      assert length(struct_phantoms) > 0
    end

    test "does not flag @behaviour as phantom", %{graph: graph} do
      diagnostics = PhantomDependency.analyze_compiled(graph)

      refute Enum.any?(diagnostics, fn diag ->
        diag.context.reference_type == :behaviour
      end), "Behaviour declarations should not be flagged as phantom"
    end
  end

  # --- RepoBypass (1.22) ---

  describe "RepoBypass (1.22)" do
    test "returns diagnostics list", %{graph: graph} do
      diagnostics = RepoBypass.analyze_compiled(graph)
      assert is_list(diagnostics)
      # Archdo has no Repo, so should be empty
      assert Enum.all?(diagnostics, &(&1.rule_id == "1.22"))
    end
  end

  # --- DegenerateFunction (6.30) ---

  describe "DegenerateFunction (6.30)" do
    test "returns diagnostics list", %{graph: graph} do
      diagnostics = DegenerateFunction.analyze_compiled(graph)
      assert is_list(diagnostics)
      assert Enum.all?(diagnostics, &(&1.rule_id == "6.30"))
    end

    test "does not flag normal GenServer callbacks", %{graph: graph} do
      diagnostics = DegenerateFunction.analyze_compiled(graph)

      refute Enum.any?(diagnostics, fn diag ->
        diag.context.function =~ "terminate/" or
          diag.context.function =~ "init/"
      end), "OTP callbacks should not be flagged as degenerate"
    end
  end

  # --- LookupTableCandidate (6.31) ---

  describe "LookupTableCandidate (6.31)" do
    test "finds lookup table candidates in Archdo", %{graph: graph} do
      diagnostics = LookupTableCandidate.analyze_compiled(graph)
      assert length(diagnostics) > 0
      assert Enum.all?(diagnostics, &(&1.rule_id == "6.31"))
    end

    test "finds severity_order as a lookup table", %{graph: graph} do
      diagnostics = LookupTableCandidate.analyze_compiled(graph)
      messages = Enum.map(diagnostics, & &1.message)

      assert Enum.any?(messages, &(&1 =~ "severity_order")),
             "severity_order/1 should be detected as a lookup table"
    end

    test "diagnostics include mapping count", %{graph: graph} do
      diagnostics = LookupTableCandidate.analyze_compiled(graph)

      Enum.each(diagnostics, fn diag ->
        assert diag.context.mapping_count >= 3
      end)
    end

    test "diagnostics include map suggestion in alternatives", %{graph: graph} do
      [diag | _] = LookupTableCandidate.analyze_compiled(graph)
      [fix | _] = diag.alternatives
      assert fix.detail =~ "@"
      assert fix.detail =~ "%{"
    end
  end

  # --- ContextQuality (1.23) ---

  describe "ContextQuality (1.23)" do
    test "produces diagnostics", %{graph: graph} do
      diagnostics = ContextQuality.analyze_compiled(graph)
      assert is_list(diagnostics)
      assert Enum.all?(diagnostics, &(&1.rule_id == "1.23"))
    end

    test "detects Archdo.Rules low cohesion", %{graph: graph} do
      diagnostics = ContextQuality.analyze_compiled(graph)
      messages = Enum.map(diagnostics, & &1.message)

      assert Enum.any?(messages, &(&1 =~ "Archdo.Rules" and &1 =~ "cohesion")),
             "Should detect low cohesion in Archdo.Rules"
    end
  end

  # --- Graph.discover_contexts/1 ---

  describe "Graph.discover_contexts/1" do
    test "discovers contexts from Archdo's own beam files", %{graph: graph} do
      contexts = Graph.discover_contexts(graph)
      assert is_list(contexts)
      assert length(contexts) > 0

      # Each context has the expected fields
      [ctx | _] = contexts
      assert is_binary(ctx.context)
      assert is_list(ctx.members)
      assert is_float(ctx.cohesion)
      assert is_float(ctx.coupling)
      assert is_float(ctx.quality_score)
    end

    test "finds the Rules context", %{graph: graph} do
      contexts = Graph.discover_contexts(graph)
      rules_ctx = Enum.find(contexts, fn c -> c.context == "Archdo.Rules" end)
      assert rules_ctx != nil
      assert length(rules_ctx.members) > 100
    end

    test "detects boundary modules when they exist", %{graph: graph} do
      contexts = Graph.discover_contexts(graph)
      compiled_ctx = Enum.find(contexts, fn c -> c.context == "Archdo.Compiled" end)

      case compiled_ctx do
        nil -> :ok
        ctx -> assert ctx.boundary_module == Archdo.Compiled
      end
    end

    test "computes cohesion and coupling as ratios between 0 and 1", %{graph: graph} do
      contexts = Graph.discover_contexts(graph)

      Enum.each(contexts, fn ctx ->
        assert ctx.cohesion >= 0.0 and ctx.cohesion <= 1.0
        assert ctx.coupling >= 0.0 and ctx.coupling <= 1.0
      end)
    end
  end
end
