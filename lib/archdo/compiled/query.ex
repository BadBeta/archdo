defmodule Archdo.Compiled.Query do
  @moduledoc false

  # §§ M-Plan19 — read API of the Compiled context. Splits the
  # 1166-line `Compiled.Graph` along its two natural responsibilities:
  # `Graph` is the BUILDER (struct + analyze + Tarjan SCC + ingest
  # helpers); `Query` is the READER (every accessor consumed by the
  # 19 Archdo.Rules.Compiled.* modules). Phase 1 implements Query as
  # `defdelegate` re-exports of Graph's existing read functions —
  # rules switch their alias to Query, the boundary metric drops, and
  # Graph's read fns can be physically moved into Query in a later
  # commit without breaking any caller.
  #
  # Type signatures continue to mention `%Graph{}` because Graph still
  # owns the struct definition — that is intentional, the data shape
  # is the contract both builder and reader operate on.

  alias Archdo.Compiled.Graph

  @type mfa_tuple :: Graph.mfa_tuple()
  @type call :: Graph.call()

  defdelegate callers_of(graph, mfa), to: Graph
  defdelegate callees_of(graph, mfa), to: Graph
  defdelegate module_dependencies(graph, module), to: Graph
  defdelegate module_dependents(graph, module), to: Graph
  defdelegate dead_functions(graph), to: Graph
  defdelegate strongly_connected_components(graph), to: Graph
  defdelegate external_usage(graph, module), to: Graph
  defdelegate callbacks_for(graph, behaviour), to: Graph
  defdelegate transitive_dependents(graph, module), to: Graph
  defdelegate blast_radius(graph, module), to: Graph
  defdelegate knows_about(graph, module), to: Graph
  defdelegate known_by(graph, module), to: Graph
  defdelegate context_knows_about(graph, context_name), to: Graph
  defdelegate context_known_by(graph, context_name), to: Graph
  defdelegate discover_contexts(graph), to: Graph
end
