defmodule Archdo.Rules do
  @moduledoc false

  # §§ M-Plan19 Phase 3 follow-up — public boundary for the Rules
  # context. The 250+ rule modules under `Archdo.Rules.*` were each
  # discovered organically; there's no single `Archdo.Rules` module
  # to anchor the boundary. External orchestrators (Runner, Mix
  # tasks, MCP tools) historically aliased individual rule modules
  # like `Archdo.Rules.Module.MainSequenceDistance` and called their
  # `analyze_project/N` directly — every such call was a measured
  # boundary leak.
  #
  # This facade exposes the rule-execution entry points that
  # external callers actually need. Each function is a defdelegate
  # to the rule module that owns the logic. Per `elixir-planning
  # §6.4`: the boundary module is the only public entry point;
  # internal rule modules stay `@moduledoc false`.

  alias Archdo.Rules.Boundary.{
    ChattyBoundary,
    FunctionBoundary,
    ShotgunSurgery,
    SyncContextCoupling
  }

  alias Archdo.Rules.Module.{FeatureEnvy, FunctionFanOut, MainSequenceDistance}
  alias Archdo.Rules.Testing.{CoverageGap, TestMirrorsSource}

  # --- Module-level metrics ---

  defdelegate main_sequence_distance(metrics, file_map), to: MainSequenceDistance, as: :analyze_project

  # --- Function-graph rules ---

  defdelegate function_boundary(fn_graph, contexts), to: FunctionBoundary, as: :analyze_project
  defdelegate function_fan_out(fn_graph), to: FunctionFanOut, as: :analyze_project
  defdelegate shotgun_surgery(fn_graph), to: ShotgunSurgery, as: :analyze_project
  defdelegate feature_envy(fn_graph), to: FeatureEnvy, as: :analyze_project
  defdelegate chatty_boundary(fn_graph, contexts), to: ChattyBoundary, as: :analyze_project
  defdelegate sync_context_coupling(fn_graph, contexts), to: SyncContextCoupling, as: :analyze_project

  # --- Test-project rules ---

  defdelegate test_mirrors_source(source_files, test_files), to: TestMirrorsSource, as: :analyze_project
  defdelegate coverage_gap(asts), to: CoverageGap, as: :analyze_project
  defdelegate coverage_matrix_report(asts), to: CoverageGap, as: :matrix_report
end
