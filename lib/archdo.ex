defmodule Archdo do
  @moduledoc """
  Architectural quality checker for Elixir.

  144 rules across 11 categories checking OTP patterns, module boundaries,
  test architecture, event sourcing, NIF safety, and more — the gap that
  Credo (style), Dialyzer (types), and Sobelow (security) don't cover.

  Uses JSV for JSON Schema validation at the MCP boundary.
  """

  alias Archdo.{AST, Config, Diagnostic, Formatter, Freeze, FunctionGraph, Graph, Metrics, Runner}
  alias Archdo.Rules.Module.MainSequenceDistance
  alias Archdo.Rules.Testing.{CoverageGap, TestMirrorsSource}

  alias Archdo.Rules.Boundary.{
    AnemicContext,
    ChattyBoundary,
    FunctionBoundary,
    GodContext,
    Mockability,
    ParallelHierarchies,
    SchemaOwnership,
    SeamIntegrity,
    ShotgunSurgery,
    SyncContextCoupling
  }

  alias Archdo.Rules.Module.{
    AdaptersWithoutBehaviour,
    DuplicatedCode,
    FatInterface,
    FeatureEnvy,
    FunctionFanOut,
    MissingTelemetry,
    SimilarCode,
    SpeculativeGenerality
  }

  @doc """
  Analyze all .ex files under the given paths and return diagnostics.
  Per-file rules only (Phase 1) unless `:boundaries` is set.
  """
  @spec run([String.t()], keyword()) :: [Archdo.Diagnostic.t()]
  def run(paths \\ ["lib"], opts \\ []) do
    files = collect_files(paths)

    per_file_diagnostics =
      case Keyword.get(opts, :boundaries, false) do
        true -> Runner.analyze_with_graph(files, opts)
        false -> Runner.analyze(files, opts)
      end

    test_diagnostics =
      case Keyword.get(opts, :tests, false) do
        true -> run_test_project_rules(paths, opts)
        false -> []
      end

    project_diagnostics = run_project_arch_rules(paths, opts)

    compiled_diagnostics =
      case Keyword.get(opts, :compiled, false) do
        true -> run_compiled_rules(paths, opts)
        false -> []
      end

    Enum.sort_by(
      per_file_diagnostics ++ test_diagnostics ++ project_diagnostics ++ compiled_diagnostics,
      fn d -> {Diagnostic.severity_order(d.severity), d.file, d.line} end
    )
  end

  @compiled_rules [
    Archdo.Rules.Compiled.DeadCode,
    Archdo.Rules.Compiled.TransitiveDeadCode,
    Archdo.Rules.Compiled.UnusedImports,
    Archdo.Rules.Compiled.CompileDependencyHotspot,
    Archdo.Rules.Compiled.WeakDependency,
    Archdo.Rules.Compiled.TestOnlyPublic,
    Archdo.Rules.Compiled.ApiSurfaceWeight,
    Archdo.Rules.Compiled.CircularFunctionCalls,
    Archdo.Rules.Compiled.ProtocolCompleteness,
    Archdo.Rules.Compiled.ChangeRisk,
    Archdo.Rules.Compiled.NonExhaustiveApi,
    Archdo.Rules.Compiled.InconsistentApiReturn,
    Archdo.Rules.Compiled.CrossBoundaryCall,
    Archdo.Rules.Compiled.InternalModuleLeak,
    Archdo.Rules.Compiled.PhantomDependency,
    Archdo.Rules.Compiled.RepoBypass,
    Archdo.Rules.Compiled.DegenerateFunction,
    Archdo.Rules.Compiled.LookupTableCandidate,
    Archdo.Rules.Compiled.ContextQuality
  ]

  defp run_compiled_rules(paths, _opts) do
    project_root =
      case paths do
        [path | _] ->
          path
          |> Path.expand()
          |> find_project_root()

        _ ->
          File.cwd!()
      end

    case Archdo.Compiled.analyze(project_root) do
      {:ok, graph} ->
        Enum.flat_map(@compiled_rules, &safe_analyze_compiled(&1, graph))

      {:error, reason} ->
        IO.puts(:standard_error, "[archdo] compiled: #{reason}")
        []
    end
  end

  # Run a single compiled rule, isolating crashes so one broken rule doesn't block others.
  defp safe_analyze_compiled(rule, graph) do
    rule.analyze_compiled(graph)
  rescue
    e ->
      IO.puts(:standard_error, "[archdo] compiled rule #{rule.id()} crashed: #{Exception.message(e)}")
      []
  end

  defp find_project_root(path) do
    cond do
      File.exists?(Path.join(path, "mix.exs")) -> path
      path == "/" -> File.cwd!()
      true -> find_project_root(Path.dirname(path))
    end
  end

  # Project-level rules that take file_asts (most common pattern).
  # New project rules only need to implement analyze_project/1.
  @project_file_ast_rules [
    Mockability,
    DuplicatedCode,
    SimilarCode,
    SpeculativeGenerality,
    ParallelHierarchies,
    SchemaOwnership,
    AdaptersWithoutBehaviour,
    SeamIntegrity,
    MissingTelemetry,
    FatInterface
  ]

  # Project-level rules that take source file paths (directory-based analysis).
  @project_file_path_rules [
    GodContext,
    AnemicContext
  ]

  defp run_project_arch_rules(paths, opts) do
    source_files = collect_files(paths)

    file_asts =
      for file <- source_files, {:ok, ast} <- [AST.parse_file(file)], do: {file, ast}

    file_ast_diagnostics =
      Enum.flat_map(@project_file_ast_rules, & &1.analyze_project(file_asts))

    file_path_diagnostics =
      Enum.flat_map(@project_file_path_rules, & &1.analyze_project(source_files))

    metrics_diagnostics = run_metrics_rules(file_asts)

    function_graph_diagnostics =
      case Keyword.get(opts, :functions, false) do
        true -> run_function_graph_rules(file_asts, opts)
        false -> []
      end

    all =
      file_ast_diagnostics ++
        file_path_diagnostics ++
        metrics_diagnostics ++
        function_graph_diagnostics

    filter_diagnostics(all, opts)
  end

  defp run_metrics_rules(file_asts) do
    # Build a module-level dep graph from the ASTs
    graph = Graph.build(file_asts)
    metrics = Metrics.compute(graph, file_asts)
    file_map = build_module_file_map(file_asts)

    MainSequenceDistance.analyze_project(metrics, file_map)
  end

  defp build_module_file_map(file_asts) do
    Map.new(file_asts, fn {file, ast} -> {AST.extract_module_name(ast), file} end)
  end

  defp run_function_graph_rules(file_asts, _opts) do
    config = Config.load()
    fn_graph = FunctionGraph.build(file_asts)

    contexts = config.contexts

    boundary_diagnostics =
      case contexts do
        [_ | _] -> FunctionBoundary.analyze_project(fn_graph, contexts)
        [] -> []
      end

    fan_out_diagnostics = FunctionFanOut.analyze_project(fn_graph)
    fan_in_diagnostics = ShotgunSurgery.analyze_project(fn_graph)
    feature_envy_diagnostics = FeatureEnvy.analyze_project(fn_graph)

    chatty_diagnostics =
      case contexts do
        [_ | _] -> ChattyBoundary.analyze_project(fn_graph, contexts)
        [] -> []
      end

    sync_coupling_diagnostics =
      case contexts do
        [_ | _] -> SyncContextCoupling.analyze_project(fn_graph, contexts)
        [] -> []
      end

    boundary_diagnostics ++
      fan_out_diagnostics ++
      fan_in_diagnostics ++
      feature_envy_diagnostics ++
      chatty_diagnostics ++
      sync_coupling_diagnostics
  end

  @doc """
  Analyze and print formatted results. Returns the exit status.

  Applies freeze filtering unless `:show_all` is set. The freeze baseline
  is loaded from `.archdo_baseline.exs` in the current working directory.
  """
  @spec run_and_format([String.t()], keyword()) :: non_neg_integer()
  def run_and_format(paths \\ ["lib"], opts \\ []) do
    diagnostics = run(paths, opts)

    final_diagnostics =
      case Keyword.get(opts, :show_all, false) do
        true ->
          diagnostics

        false ->
          baseline = Freeze.load()
          {new, _baselined} = Freeze.partition(diagnostics, baseline)
          new
      end

    Formatter.format(final_diagnostics, opts)
  end

  @doc """
  Run analysis and save the current violations as a baseline.
  Returns 0 on success.
  """
  @spec freeze_baseline([String.t()], keyword()) :: non_neg_integer()
  def freeze_baseline(paths \\ ["lib"], opts \\ []) do
    diagnostics = run(paths, opts)
    Freeze.save(diagnostics)

    IO.puts(
      "\nArchdo — baseline saved (#{length(diagnostics)} diagnostics frozen at .archdo_baseline.exs)\n"
    )

    IO.puts("Subsequent `mix archdo` runs will only show NEW violations.")
    IO.puts("To see everything, use `mix archdo --show-all`.")
    0
  end

  @doc """
  Print baseline stats: how many baselined violations are still present,
  how many were resolved, how many new violations exist.
  """
  @spec freeze_stats([String.t()], keyword()) :: non_neg_integer()
  def freeze_stats(paths \\ ["lib"], opts \\ []) do
    diagnostics = run(paths, opts)
    baseline = Freeze.load()
    stats = Freeze.stats(diagnostics, baseline)

    IO.puts("""

    Archdo — Baseline Status

      Baseline fingerprints:  #{stats.baseline_size}
      Still present:          #{stats.still_present}
      Resolved (fixed):       #{stats.resolved}  #{medal(stats.resolved)}
      New since baseline:     #{stats.new}  #{warning(stats.new)}
      Current total:          #{stats.current}
    """)

    if stats.new > 0, do: 1, else: 0
  end

  defp medal(0), do: ""
  defp medal(n) when n < 5, do: "✓"
  defp medal(n) when n < 20, do: "✓✓"
  defp medal(_), do: "✓✓✓"

  defp warning(0), do: ""
  defp warning(n) when n < 5, do: "(small)"
  defp warning(n) when n < 20, do: "(moderate)"
  defp warning(_), do: "(large)"

  defp run_test_project_rules(paths, opts) do
    source_files = collect_files(paths)
    test_files = Path.wildcard("test/**/*_test.exs")

    mirror_diagnostics = TestMirrorsSource.analyze_project(source_files, test_files)

    # Coverage gap needs source + test ASTs
    source_asts = parse_many(source_files)
    test_asts = parse_many(test_files)
    coverage_diagnostics = CoverageGap.analyze_project(source_asts ++ test_asts)

    filter_diagnostics(mirror_diagnostics ++ coverage_diagnostics, opts)
  end

  @doc """
  Print a test coverage gap matrix for the project.
  Returns 0 (this command never fails; it just reports).
  """
  @spec print_coverage_matrix([String.t()]) :: non_neg_integer()
  def print_coverage_matrix(paths \\ ["lib"]) do
    source_files = collect_files(paths)
    test_files = collect_tests_for(paths)

    source_asts = parse_many(source_files)
    test_asts = parse_many(test_files)

    IO.write(CoverageGap.matrix_report(source_asts ++ test_asts))

    0
  end

  @doc """
  Print a Martin metrics matrix (Ca/Ce/I/A/D) for the project.
  Modules sorted by distance from main sequence (worst first).
  """
  @spec print_metrics_matrix([String.t()]) :: non_neg_integer()
  def print_metrics_matrix(paths \\ ["lib"]) do
    source_files = collect_files(paths)
    file_asts = parse_many(source_files)

    graph = Graph.build(file_asts)
    metrics = Metrics.compute(graph, file_asts)

    metrics
    |> Enum.sort_by(& &1.distance, :desc)
    |> format_metrics_table()
    |> IO.write()

    0
  end

  defp format_metrics_table([]), do: "\nArchdo — no modules analyzed.\n"

  defp format_metrics_table(metrics) do
    header = [
      "\nArchdo — Martin Package Metrics\n\n",
      "Ca = afferent coupling (how many depend on you)\n",
      "Ce = efferent coupling (how many you depend on)\n",
      "I  = instability (Ce / (Ca + Ce))\n",
      "A  = abstractness (behaviour/protocol = 1.0, concrete = 0.0)\n",
      "D  = distance from main sequence — 0 good, 1 problematic\n\n",
      :io_lib.format("~-55ts ~4ts ~4ts ~6ts ~6ts ~6ts~n", ["Module", "Ca", "Ce", "I", "A", "D"]),
      String.duplicate("-", 88),
      "\n"
    ]

    rows =
      Enum.map(metrics, fn m ->
        :io_lib.format("~-55ts ~4w ~4w ~6.2f ~6.2f ~6.2f~n", [
          truncate(m.module, 55),
          m.ca,
          m.ce,
          m.instability,
          m.abstractness,
          m.distance
        ])
      end)

    total_distance =
      metrics
      |> Enum.map(& &1.distance)
      |> Enum.sum()
    avg_distance = total_distance / length(metrics)

    footer = [
      String.duplicate("-", 88),
      "\n",
      :io_lib.format("Average distance from main sequence: ~.2f~n~n", [avg_distance])
    ]

    [header, rows, footer]
  end

  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max - 3) <> "..."

  # Find test files near each source path. For /foo/bar/lib → /foo/bar/test.
  defp collect_tests_for(paths) do
    paths
    |> Enum.flat_map(fn path ->
      project_root =
        cond do
          String.ends_with?(path, "/lib") -> Path.dirname(path)
          String.ends_with?(path, "lib") and File.dir?(Path.join(path, "..")) -> Path.dirname(path)
          true -> "."
        end

      Path.wildcard(Path.join(project_root, "test/**/*_test.exs"))
    end)
    |> Enum.uniq()
  end

  defp parse_many(files) do
    for file <- files, {:ok, ast} <- [AST.parse_file(file)], do: {file, ast}
  end

  defp filter_diagnostics(diagnostics, opts) do
    ignore = Keyword.get(opts, :ignore, [])
    only = Keyword.get(opts, :only)

    Enum.filter(diagnostics, fn d ->
      cond do
        only && d.rule_id not in only -> false
        d.rule_id in ignore -> false
        true -> true
      end
    end)
  end

  @doc """
  Collect all .ex and .exs files under the given paths.
  """
  @spec collect_files([String.t()]) :: [String.t()]
  def collect_files(paths) do
    paths
    |> Enum.flat_map(fn path ->
      cond do
        File.regular?(path) -> [path]
        File.dir?(path) ->
          Path.wildcard(Path.join(path, "**/*.ex")) ++
            Path.wildcard(Path.join(path, "**/*.exs"))

        true ->
          []
      end
    end)
    |> Enum.sort()
    |> Enum.uniq()
  end

end
