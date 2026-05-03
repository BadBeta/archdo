defmodule Archdo.Compiled do
  @moduledoc """
  Project-wide compiled-mode analysis facade. Compilation-tracer-based
  cross-reference: when a project is compiled with Archdo's tracer
  enabled, this module captures every remote function call, import,
  struct expansion, and module definition.

  Ground-truth data the AST analysis can't provide:

    - Macro-injected functions (visible after expansion)
    - Resolved imports (which module each unqualified call targets)
    - Protocol dispatch targets
    - Dead code detection (exported functions never called)
    - Complete behaviour callback lists (including @optional_callbacks)

  Stable public API: every `Archdo.Rules.Compiled.*` rule consumes the
  query functions defdelegated below. The opaque `Compiled.t()` type
  alias hides the internal `Compiled.Graph` struct so callers don't
  pattern-match its fields.
  """

  # Reading beam files from `_build/*/lib/*/ebin` IS the responsibility.
  Module.register_attribute(__MODULE__, :archdo_volatility, persist: true)
  @archdo_volatility :stable

  # `{:error, _}` returned to caller (archdo.ex prints to stderr).
  Module.register_attribute(__MODULE__, :archdo_silent_error, persist: true)
  @archdo_silent_error true

  alias Archdo.Compiled.{Graph, Query}

  # §§ M-Plan19 Phase 3 — public type alias so external @spec lines
  # write `Compiled.t()` instead of `Compiled.Graph.t()`. Keeps the
  # internal struct module name out of consumers' type signatures.
  @type t :: Graph.t()

  # §§ M-Plan19 — public read API of the Compiled context. The 15
  # query functions live in `Compiled.Query`; this facade re-exports
  # them so callers can write `Compiled.callers_of(graph, mfa)`
  # without aliasing an internal module. `analyze/1` (below) is the
  # only function that performs I/O.
  defdelegate callers_of(graph, mfa), to: Query
  defdelegate callees_of(graph, mfa), to: Query
  defdelegate module_dependencies(graph, module), to: Query
  defdelegate module_dependents(graph, module), to: Query
  defdelegate dead_functions(graph), to: Query
  defdelegate strongly_connected_components(graph), to: Query
  defdelegate external_usage(graph, module), to: Query
  defdelegate callbacks_for(graph, behaviour), to: Query
  defdelegate transitive_dependents(graph, module), to: Query
  defdelegate blast_radius(graph, module), to: Query
  defdelegate knows_about(graph, module), to: Query
  defdelegate known_by(graph, module), to: Query
  defdelegate context_knows_about(graph, context_name), to: Query
  defdelegate context_known_by(graph, context_name), to: Query
  defdelegate discover_contexts(graph), to: Query

  # §§ M-Plan19 (Phase 2) — build-side helpers exposed through the
  # boundary so rules that need clause-shape data (NonExhaustiveApi,
  # InconsistentApiReturn) or raw export sets (DegenerateFunction,
  # LookupTableCandidate) call through `Compiled` instead of into
  # `Compiled.Graph`. Path-taking signatures — these don't take a
  # graph; they read beam files.
  defdelegate extract_function_clauses(beam_dir), to: Graph
  defdelegate collect_exports_from_forms(forms), to: Graph

  # §§ M-Plan19 Phase 3 — diagram generators are part of the Compiled
  # context's public API. Exposing them through the boundary lets
  # consumers (Mix task, MCP tools) call `Compiled.architecture_overview/1`
  # without knowing which internal Diagram* module owns each renderer.
  defdelegate architecture_overview(graph), to: __MODULE__.Diagram
  defdelegate context_detail(graph, name), to: __MODULE__.Diagram
  defdelegate module_dependencies(graph), to: __MODULE__.Diagram
  defdelegate api_surface(graph), to: __MODULE__.Diagram
  defdelegate dependency_delta(graph, paths), to: __MODULE__.Diagram
  defdelegate dependency_delta_only(graph, paths), to: __MODULE__.Diagram
  defdelegate dataflow_module(graph, module), to: __MODULE__.Diagram
  defdelegate dataflow_context(graph, name), to: __MODULE__.Diagram
  defdelegate blast_radius_diagram(graph, module), to: __MODULE__.Diagram, as: :blast_radius

  defdelegate module_dataflow_svg(graph, module), to: __MODULE__.DiagramSVG, as: :module_dataflow
  defdelegate context_dataflow_svg(graph, name), to: __MODULE__.DiagramSVG, as: :context_dataflow

  defdelegate supervision_diagram(graph), to: __MODULE__.DiagramOTP
  defdelegate messaging_diagram(graph), to: __MODULE__.DiagramOTP

  defdelegate system_diagram(graph), to: __MODULE__.DiagramSystem

  defdelegate interactive_html(graph), to: __MODULE__.DiagramInteractive, as: :generate

  # §§ M-Plan19 Phase 3 — boundary accessors per elixir-planning §4.12.
  # The accessor implementations live on Graph (only the type's
  # defining module may destructure an `@opaque` struct). Compiled
  # defdelegates them so external callers go through the boundary.
  defdelegate calls(graph), to: Graph
  defdelegate modules(graph), to: Graph
  defdelegate calls_by_module(graph), to: Graph
  defdelegate calls_by_callee(graph), to: Graph
  defdelegate calls_by_caller(graph), to: Graph
  defdelegate beam_dir(graph), to: Graph
  defdelegate protocol_impls(graph), to: Graph

  @doc """
  Analyze a project directory by reading compiled beam files and building
  a complete interaction graph.

  Returns `{:ok, %Compiled.Graph{}}` or `{:error, reason}`.

  The graph contains:
    - `:modules` — map of module => %{exports, behaviours, struct_fields, callback_fns}
    - `:calls` — list of %{caller: mfa, callee: mfa, line: N}
    - `:calls_by_caller` — indexed by caller MFA
    - `:calls_by_callee` — indexed by callee MFA
    - `:calls_by_module` — indexed by caller module
    - `:protocol_impls` — protocol => [impl_modules]
    - `:struct_expansions` — struct usage tracking
  """
  @spec analyze(String.t()) :: {:ok, Graph.t()} | {:error, String.t()}
  def analyze(project_path) do
    case find_beam_dir(project_path) do
      nil ->
        {:error, "No compiled beam files found. Run `mix compile` in the target project first."}

      dir ->
        app_name = detect_app_name(project_path)

        graph =
          dir
          |> Graph.build()
          |> Graph.with_metadata(app_name: app_name, beam_dir: dir)

        {:ok, graph}
    end
  end

  # --- I/O Boundary (impure shell) ---

  defp find_beam_dir(project_path) do
    build_dir = Path.join(project_path, "_build")

    case detect_app_name(project_path) do
      nil ->
        nil

      app_name ->
        # Look for _build/ENV/lib/APP/ebin — try dev first, then prod
        Enum.find_value(["dev", "prod", "test"], &beam_dir_for_env(&1, build_dir, app_name))
    end
  end

  defp beam_dir_for_env(env, build_dir, app_name) do
    dir = Path.join([build_dir, env, "lib", app_name, "ebin"])
    valid_beam_dir(File.dir?(dir) and Path.wildcard(Path.join(dir, "*.beam")) != [], dir)
  end

  # §§ elixir-implementing: §2.1 — boolean → multi-clause head
  defp valid_beam_dir(false, _dir), do: nil
  defp valid_beam_dir(true, dir), do: dir

  defp detect_app_name(project_path) do
    mix_file = Path.join(project_path, "mix.exs")

    case File.read(mix_file) do
      {:ok, content} ->
        case Regex.run(~r/app:\s*:(\w+)/, content) do
          [_, name] -> name
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
