defmodule Archdo do
  @moduledoc """
  Architectural quality checker for Elixir.

  Archdo fills the gap left by `Credo` (style), `Dialyzer` (types), and
  `Sobelow` (security) — the architecture-and-design layer: OTP discipline,
  context boundaries, coupling, test architecture, NIF safety, event
  sourcing, state machines, and module quality.

  ## Two-layer review

  Archdo is **Layer 1**: a fast, mechanical scan that produces structured
  findings. **Layer 2** is the human (or an LLM with a domain skill loaded)
  who decides which findings represent intentional trade-offs and which
  warrant action. Every output format ends with a pointer to the relevant
  Elixir/rust-nif skill section so the hand-off is concrete.

  ## What it ships

    * **203 rules** across 11 categories (boundaries, coupling, OTP, module
      quality, single-source-of-truth, testing, event sourcing, state
      machines, composition, native interop, public API).
    * **8 output formats**: `summary` (default tally table), `text` (full
      why+fixes), `brief` (warns/errors with fixes, info elided), `compact`
      (one-line per finding), `json`, `llm` (NDJSON for tooling), `sarif`
      (GitHub Code Scanning), `html`.
    * **MCP server** (`mix archdo.mcp`) exposing 13 JSON-RPC 2.0 tools so
      LLMs can analyze, explain, diagram, and (experimentally) auto-fix.
    * **Baseline / freeze workflow** for adopting Archdo on a legacy
      codebase: `mix archdo --freeze` captures current violations as a
      baseline; subsequent runs report only NEW violations.
    * **Compiled-beam analysis** (`--compiled`) for dead code, transitive
      dead code, macro-aware behaviour checks, and a precise call graph.
    * **Architecture diagrams** (`--diagram`) — Mermaid context overviews,
      module dependencies, blast-radius views, and an interactive
      LabVIEW-style HTML viewer.
    * **Per-finding suppression** via `# archdo:allow RULE_ID` comments.

  Uses JSV for JSON Schema validation at the MCP boundary.

  ## Quick start

      $ mix archdo                 # Phase 1 scan against ./lib
      $ mix archdo --format text   # full why+fixes per finding
      $ mix archdo --freeze        # accept current violations as baseline
      $ mix archdo --explain 11.1  # explain a specific rule

  See `mix help archdo` for the full CLI surface.
  """

  alias Archdo.{
    AST,
    Config,
    Diagnostic,
    Formatter,
    Freeze,
    Graph,
    Metrics,
    Phoenix,
    Quadrant,
    Runner,
    Severity
  }
  alias Archdo.Rules.Testing.MissingBoundaryTests

  alias Archdo.Rules.Boundary.{
    AnemicContext,
    GodContext,
    Mockability,
    ParallelHierarchies,
    SchemaOwnership,
    SeamIntegrity
  }

  alias Archdo.Rules.Module.{
    AdaptersWithoutBehaviour,
    DuplicatedCode,
    FatInterface,
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

    # §§ elixir-implementing: §10.5 — load .archdo.exs once at the
    # entry point and thread through opts. Downstream rules that
    # honour configurable thresholds (1.6 max_logger_calls, 1.11
    # min_files, etc.) read opts[:config] via Archdo.Config.threshold/4.
    # Lazy-load preserves the test seam: callers passing :config win.
    opts = Keyword.put_new_lazy(opts, :config, fn -> Config.load() end)

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
    Archdo.Rules.Compiled.ContextQuality,
    Archdo.Rules.Compiled.CircularContextDeps,
    Archdo.Rules.Compiled.OrphanModule
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
      IO.puts(
        :standard_error,
        "[archdo] compiled rule #{rule.id()} crashed: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

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
    FatInterface,
    MissingBoundaryTests,
    Archdo.Rules.Boundary.SharedDbTable,
    Archdo.Rules.Boundary.SharedEtsTable,
    Archdo.Rules.CE.WrapperOverFramework,
    Archdo.Rules.CE.UnanchoredModule,
    Archdo.Rules.CE.UnanchoredIsland,
    Archdo.Rules.CE.MagicLiterals,
    Archdo.Rules.CE.VolatilitySubstitutability,
    Archdo.Rules.CE.ScatteredTaxonomy,
    Archdo.Rules.CE.ContractDensity,
    Archdo.Rules.CE.ContractDensitySpecs,
    Archdo.Rules.CE.ReturnShapeDrift,
    Archdo.Rules.CE.ErrorCategoryDrift,
    Archdo.Rules.CE.MissingTraceability,
    Archdo.Rules.CE.MissingRetentionPolicy,
    Archdo.Rules.CE.UntestedBuildingBlock,
    Archdo.Rules.CE.PiiFieldHandling,
    Archdo.Rules.CE.MissingDeletionPath,
    Archdo.Rules.CE.DeadRequirement
  ]

  # Project-level rules that take source file paths (directory-based analysis).
  @project_file_path_rules [
    GodContext,
    AnemicContext
  ]

  @doc "All project-level rules combined — used by --list-packs."
  @spec project_rules() :: [module()]
  def project_rules, do: @project_file_ast_rules ++ @project_file_path_rules

  defp run_project_arch_rules(paths, opts) do
    source_files = collect_files(paths)

    file_asts =
      for file <- source_files, {:ok, ast} <- [AST.parse_file(file)], do: {file, ast}

    file_ast_diagnostics =
      Enum.flat_map(@project_file_ast_rules, &invoke_project_rule(&1, file_asts, opts))

    file_path_diagnostics =
      Enum.flat_map(
        @project_file_path_rules,
        &invoke_project_path_rule(&1, source_files, opts)
      )

    metrics_diagnostics = Runner.run_metrics_rules(file_asts)

    function_graph_diagnostics =
      case Keyword.get(opts, :functions, false) do
        true -> Runner.run_function_graph_rules(file_asts, opts)
        false -> []
      end

    # §§ elixir-planning: §6 — apply M8/M9 severity calibration to project-
    # level diagnostics. Per-file rules are calibrated in Runner.analyze_file/3
    # using the file's classification; project-level rules (graph, metrics,
    # cross-file) classify with `nil` so per-rule overrides still fire while
    # layer-based downgrades don't apply (no single file to classify).
    all =
      (file_ast_diagnostics ++
         file_path_diagnostics ++
         metrics_diagnostics ++
         function_graph_diagnostics)
      |> Enum.map(&calibrate_project_diagnostic(&1, file_asts))

    filter_diagnostics(all, opts)
  end

  # Project rules may take 1 or 2 args. Newer rules accept opts; older
  # rules don't. Dispatch by arity so existing rules keep working.
  # Wrapped in rescue so one broken rule doesn't block the rest.
  #
  # `Code.ensure_loaded` is critical: function_exported?/3 returns false
  # for any function on an unloaded module — without ensure_loaded we'd
  # always fall through to the /1 branch, silently dropping opts.
  defp invoke_project_rule(rule, file_asts, opts) do
    _ = Code.ensure_loaded(rule)

    case function_exported?(rule, :analyze_project, 2) do
      true -> rule.analyze_project(file_asts, opts)
      false -> rule.analyze_project(file_asts)
    end
  rescue
    e ->
      IO.puts(
        :standard_error,
        "[archdo] project rule #{rule.id()} crashed: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      []
  end

  # §§ elixir-implementing: §10.5 — same arity-aware dispatch for
  # path-only project rules so threshold-aware ones (1.11 min_files)
  # can read opts[:config] without breaking older /1 rules.
  defp invoke_project_path_rule(rule, source_files, opts) do
    _ = Code.ensure_loaded(rule)

    case function_exported?(rule, :analyze_project, 2) do
      true -> rule.analyze_project(source_files, opts)
      false -> rule.analyze_project(source_files)
    end
  rescue
    e ->
      IO.puts(
        :standard_error,
        "[archdo] project rule #{rule.id()} crashed: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      []
  end

  defp calibrate_project_diagnostic(diag, file_asts) do
    classification =
      case Enum.find(file_asts, fn {file, _} -> file == diag.file end) do
        {_file, ast} -> Phoenix.classify_file(diag.file, ast)
        nil -> nil
      end

    Severity.adjust_diagnostic(diag, classification)
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
    Runner.run_test_project_rules(source_files, test_files, opts)
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

    IO.write(Runner.coverage_matrix_report(source_asts, test_asts))

    0
  end

  @doc """
  M-Aux4 audit: print modules + contexts that pass the Blackbox
  building-block verdict (every public function ≥ 0.9 possibility).
  """
  @spec print_building_blocks([String.t()]) :: non_neg_integer()
  def print_building_blocks(paths \\ ["lib"]) do
    source_files = collect_files(paths)
    file_asts = parse_many(source_files)

    module_results =
      file_asts
      |> Enum.map(fn {file, ast} ->
        module = AST.extract_module_name(ast)
        verdict = Archdo.Blackbox.module_verdict(ast)
        {module, file, ast, verdict}
      end)
      |> Enum.reject(fn {module, _, _, _} -> module == "Unknown" end)

    {blocks, leaks} =
      Enum.split_with(module_results, fn {_, _, _, v} -> v == :building_block end)

    IO.puts("\nArchdo — Building Block Audit (M-Aux4)\n")
    IO.puts("Modules where EVERY public function scores ≥ 0.9 on the Blackbox\n" <>
            "possibility metric (input_closure × determinism × output_completeness ×\n" <>
            "totality × side_effect_free × errors_as_values).\n")

    IO.puts("─── Building-block MODULES (#{length(blocks)} of #{length(module_results)}) ───\n")

    case blocks do
      [] ->
        IO.puts("  (none — likely missing @spec coverage; see --metrics for breakdown)\n")

      list ->
        list
        |> Enum.map(fn {m, _, _, _} -> m end)
        |> Enum.sort()
        |> Enum.each(&IO.puts("  ✓ #{&1}"))

        IO.puts("")
    end

    # Context audit: for each module that classifies as a :context per
    # Phoenix.classify_file, check whether the entire namespace is a
    # building block.
    context_modules =
      file_asts
      |> Enum.flat_map(fn {file, ast} ->
        case Phoenix.classify_file(file, ast).layer do
          :context -> [AST.extract_module_name(ast)]
          _ -> []
        end
      end)
      |> Enum.uniq()
      |> Enum.sort()

    case context_modules do
      [] ->
        :ok

      contexts ->
        verdicts =
          Enum.map(contexts, fn ctx ->
            {ctx, Archdo.Blackbox.context_verdict(file_asts, ctx)}
          end)

        building_block_contexts = Enum.filter(verdicts, fn {_, v} -> v == :building_block end)

        IO.puts(
          "─── Building-block CONTEXTS (#{length(building_block_contexts)} of #{length(contexts)}) ───\n"
        )

        Enum.each(verdicts, fn
          {ctx, :building_block} ->
            IO.puts("  ✓ #{ctx}")

          {ctx, {:leaks_at, modules}} ->
            preview = modules |> Enum.take(3) |> Enum.join(", ")
            more = if length(modules) > 3, do: " (+#{length(modules) - 3} more)", else: ""
            IO.puts("  ✗ #{ctx} — leaks: #{preview}#{more}")
        end)

        IO.puts("")
    end

    print_near_block_section(leaks)

    IO.puts(
      "\nLeaks summary: #{length(leaks)} modules have at least one impure or " <>
        "spec-less public function."
    )

    0
  end

  # M-Aux5: rank non-block modules by refactor distance (count of failed
  # components across all public fns) and print the top-20 with their
  # boundary suggestion.
  defp print_near_block_section([]), do: :ok

  defp print_near_block_section(leaks) do
    ranked =
      leaks
      |> Enum.map(fn {module, _file, ast, _verdict} ->
        distance = Archdo.Blackbox.refactor_distance(ast)
        suggestion = Archdo.Blackbox.boundary_suggestion(ast)
        {module, distance, suggestion}
      end)
      |> Enum.sort_by(fn {_, d, _} -> d end)

    IO.puts(
      "\n─── Near-block modules (top 20 by refactor distance, M-Aux5) ───\n" <>
        "  Distance = total failed components across all public fns.\n"
    )

    ranked
    |> Enum.take(20)
    |> Enum.each(fn {module, distance, suggestion} ->
      IO.puts("  d=#{distance} #{module}")
      IO.puts("    " <> format_suggestion(suggestion))
    end)

    IO.puts("")
  end

  defp format_suggestion(:building_block), do: "→ already a building block"

  defp format_suggestion({:extract, leaky, pure}) do
    leaky_repr = leaky |> Enum.take(3) |> Enum.map_join(", ", fn {n, a} -> "#{n}/#{a}" end)
    pure_repr = pure |> Enum.take(3) |> Enum.map_join(", ", fn {n, a} -> "#{n}/#{a}" end)
    extra = if length(leaky) > 3, do: " (+#{length(leaky) - 3})", else: ""

    "→ EXTRACT #{length(leaky)} leaky fn(s) [#{leaky_repr}#{extra}]; " <>
      "remaining #{length(pure)} fn(s) [#{pure_repr}] become a building block"
  end

  defp format_suggestion({:refactor_in_place, breakdown}) do
    sorted =
      breakdown
      |> Enum.sort_by(fn {_k, v} -> -v end)
      |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{v}" end)

    "→ REFACTOR IN PLACE — pure subset depends on leaks; failures: #{sorted}"
  end

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

    print_quadrant_distributions(file_asts)
    print_blackbox_summary(file_asts)

    0
  end

  # §§ elixir-planning: §6 — M25 Blackbox metric exposure. Per-module
  # blackbox possibility score + class distribution. Pure measurement;
  # no rule fires from these numbers (M26 will add CE-54/55/56 quadrant).
  defp print_blackbox_summary(file_asts) do
    per_module =
      file_asts
      |> Enum.map(fn {file, ast} ->
        scores = Archdo.Blackbox.score_module(ast)

        case scores do
          [] -> nil
          list ->
            possibility = list |> Enum.map(fn {_, _, s, _} -> s end) |> Enum.sum() |> Kernel./(length(list))
            module = AST.extract_module_name(ast)
            {module, file, possibility, Archdo.Blackbox.classify(possibility)}
        end
      end)
      |> Enum.reject(&is_nil/1)

    case per_module do
      [] ->
        :ok

      _ ->
        IO.puts("\nArchdo — Blackbox Possibility (Group O axis 1)\n")
        IO.puts("Per-module mean of (input_closure × determinism × output_completeness ×")
        IO.puts("totality × side_effect_free × errors_as_values).\n")

        IO.puts(
          :io_lib.format("~-55ts ~10ts ~-15ts~n", ["Module", "Possibility", "Class"])
        )

        IO.puts(String.duplicate("-", 84))

        per_module
        |> Enum.sort_by(fn {_, _, p, _} -> p end)
        |> Enum.take(20)
        |> Enum.each(fn {module, _file, p, class} ->
          IO.puts(
            :io_lib.format("~-55ts ~10.3f ~-15ts~n", [
              truncate(module, 55),
              p,
              Atom.to_string(class)
            ])
          )
        end)

        # Class distribution
        dist = per_module |> Enum.frequencies_by(fn {_, _, _, c} -> c end)
        IO.puts("\nClass distribution: #{inspect(dist)}\n")
    end
  end

  # §§ elixir-planning: §6 — Quadrant rules surface their cell distribution
  # alongside the Martin metrics table. Each registered quadrant rule
  # contributes a small per-cell count map, aggregated across analyzed
  # files. Empty section when no quadrant rules exist (current state until
  # CE-2/3 lands), so the column shape is in place from M14 onward.
  defp print_quadrant_distributions(file_asts) do
    rules =
      (Runner.phase1_rules() ++ Runner.graph_rules())
      |> Quadrant.list_rules()

    case rules do
      [] ->
        :ok

      _ ->
        IO.puts("\nArchdo — Quadrant Rule Cell Distributions\n")

        Enum.each(rules, fn rule ->
          totals =
            Enum.reduce(file_asts, %{}, fn {file, ast}, acc ->
              rule
              |> Quadrant.distribution_for(file, ast, [])
              |> Map.merge(acc, fn _cell, a, b -> a + b end)
            end)

          IO.puts("  #{rule.id()} — #{rule.description()}")

          totals
          |> Enum.sort_by(fn {cell, _} -> inspect(cell) end)
          |> Enum.each(fn {cell, count} ->
            IO.puts("    #{inspect(cell)}: #{count}")
          end)

          IO.puts("")
        end)
    end
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
          String.ends_with?(path, "/lib") ->
            Path.dirname(path)

          String.ends_with?(path, "lib") and File.dir?(Path.join(path, "..")) ->
            Path.dirname(path)

          true ->
            "."
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
        File.regular?(path) ->
          [path]

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
