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

    * **262 rules** across 13 categories (boundaries, coupling, change
      economy, OTP, module quality, single-source-of-truth, testing, event
      sourcing, state machines, composition, native interop, public API,
      error handling).
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

  # CLI tool entry point — File / project-root resolution IS the
  # responsibility. Substitutability via behaviour seam doesn't apply
  # here; tests exercise this module via real `System.tmp_dir!` paths.
  Module.register_attribute(__MODULE__, :archdo_volatility, persist: true)
  @archdo_volatility :stable

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
    Rules,
    Runner,
    Severity
  }

  alias Archdo.Compiled.Graph.Centrality
  alias Archdo.Stats.{FunctionMetrics, Halstead, Loc}

  # §§ elixir-planning: §6 — observability deferred to the consumer.
  # Archdo is a library / CLI tool. Its callers (mix archdo, the MCP
  # server, interactive IEx) do their own logging / progress reporting;
  # adding :telemetry.span here would require an extra dep for
  # spans nobody attaches to. Rule 4.19's @archdo_no_telemetry
  # exemption applies.
  Module.register_attribute(__MODULE__, :archdo_no_telemetry, persist: true)

  @archdo_no_telemetry "library/CLI — observability is the caller's responsibility (mix task, MCP, IEx)"

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

    # §§ elixir-implementing: §10.5 — build the compiled graph once when
    # `--compiled` is set and thread it via opts so project-arch rules
    # (CE-30) can cross-suppress macro-driven false positives, and
    # compiled rules (1.25, 1.26, etc.) can consume it without rebuilding.
    {opts_with_graph, compiled_graph} = maybe_attach_compiled_graph(opts, paths)

    project_diagnostics = run_project_arch_rules(paths, opts_with_graph)

    compiled_diagnostics =
      case compiled_graph do
        nil -> []
        graph -> run_compiled_rules_with_graph(graph, opts_with_graph)
      end

    (per_file_diagnostics ++ test_diagnostics ++ project_diagnostics ++ compiled_diagnostics)
    |> apply_cleanup_pass_filter(Keyword.get(opts, :cleanup_pass))
    |> Archdo.ReportTier.filter(Keyword.get(opts, :report_tier))
    |> Enum.sort_by(fn d -> {Diagnostic.severity_order(d.severity), d.file, d.line} end)
  end

  # §§ elixir-planning: §10.5 — diagnostic-level filter applied AFTER all
  # subsystems run, so phase1, graph, project-arch, and compiled findings
  # get filtered by the same cleanup-pass rule. The rule-level filter in
  # Runner.filter_rules already prunes phase1/graph rules; this step
  # catches the project-arch and compiled findings whose rules don't
  # route through the runner's filter pipeline.
  defp apply_cleanup_pass_filter(diagnostics, nil), do: diagnostics

  defp apply_cleanup_pass_filter(diagnostics, pass) when is_integer(pass) do
    Enum.filter(diagnostics, fn d -> Archdo.CleanupPass.pass_for(d.rule_id) == pass end)
  end

  # Compiled-mode rule list lives on `Archdo.Rules` — see `Rules.compiled_rules/0`.

  # Build the compiled graph once when --compiled is set, and put both
  # the graph itself (opts[:compiled_graph]) and a precomputed MapSet of
  # modules with non-empty incoming edges (opts[:compiled_reached_modules])
  # into opts. The MapSet is the seam CE-30 uses to cross-suppress
  # macro-driven false positives.
  defp maybe_attach_compiled_graph(opts, paths) do
    case Keyword.get(opts, :compiled, false) do
      false ->
        {opts, nil}

      true ->
        case build_compiled_graph(paths) do
          {:ok, graph} ->
            reached = compute_reached_modules(graph)

            {anchors, ast_graph, library_publics, impl_annotated, source_defs, macro_emit_edges} =
              compute_ast_anchors_and_graph(paths)

            new_opts =
              opts
              |> Keyword.put(:compiled_graph, graph)
              |> Keyword.put(:compiled_reached_modules, reached)
              |> Keyword.put(:ast_anchor_modules, anchors)
              |> Keyword.put(:ast_graph, ast_graph)
              |> Keyword.put(:library_public_modules, library_publics)
              |> Keyword.put(:impl_annotated_functions, impl_annotated)
              |> Keyword.put(:source_defined_functions, source_defs)
              |> Keyword.put(:macro_emit_edges, macro_emit_edges)

            {new_opts, graph}

          {:error, reason} ->
            IO.puts(:standard_error, "[archdo] compiled: #{reason}")
            {opts, nil}
        end
    end
  end

  # Compute AST-side anchors AND build the AST graph in one pass — both
  # are needed by 1.26 (compiled/unanchored_module) which unions
  # compiled-graph function edges with AST :registry edges.
  defp compute_ast_anchors_and_graph(paths) do
    files = collect_files(paths)
    file_asts = for file <- files, {:ok, ast} <- [AST.parse_file(file)], do: {file, ast}
    production = Enum.reject(file_asts, fn {file, _} -> AST.test_file?(file) end)

    anchors =
      production
      |> Archdo.AnchorSet.compute()
      |> MapSet.to_list()
      |> Enum.map(&AST.safe_existing_atom/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    ast_graph = Graph.build(production)
    library_publics = compute_library_public_modules(production, paths)
    impl_annotated = compute_impl_annotated_functions(production)
    source_defs = compute_source_defined_functions(production)
    macro_emit_edges = compute_macro_emit_edges(production)

    {anchors, ast_graph, library_publics, impl_annotated, source_defs, macro_emit_edges}
  end

  # Build `module_atom => [module_atom]` of virtual call edges from
  # `defmacro` bodies. Compiled-rule 1.26 consumes this to reach modules
  # that are referenced ONLY inside library macros (the call materializes
  # in the consumer's compiled module, never the library's). Source
  # modules whose macros emit no recognised references contribute nothing.
  defp compute_macro_emit_edges(production_asts) do
    for {_file, ast} <- production_asts,
        {source_str, target_strs} <- Archdo.AST.MacroEdges.extract(ast),
        source_atom = AST.safe_existing_atom(source_str),
        not is_nil(source_atom),
        target_atoms =
          target_strs
          |> Enum.map(&AST.safe_existing_atom/1)
          |> Enum.reject(&is_nil/1),
        target_atoms != [],
        reduce: %{} do
      acc -> Map.update(acc, source_atom, target_atoms, &Enum.uniq(&1 ++ target_atoms))
    end
  end

  # Build `module_atom => MapSet({fn, arity})` of every `def`/`defp` defined
  # in source AST. Compiled-rule 6.24 (DeadCode) consumes this to detect
  # macro-injected callback defaults — functions that exist in the compiled
  # BEAM but not in source. Combined with `behaviour_implementor?`, those
  # are flagged as macro-injected and skipped from dead-code findings.
  defp compute_source_defined_functions(production_asts) do
    for {_file, ast} <- production_asts,
        module = AST.extract_module_name(ast),
        module != "Unknown",
        atom = AST.safe_existing_atom(module),
        not is_nil(atom),
        defs = collect_module_defs(ast),
        into: %{},
        do: {atom, defs}
  end

  defp collect_module_defs(ast) do
    ast
    |> AST.extract_functions(:all)
    |> Enum.reduce(MapSet.new(), fn {name, arity, _meta, _args, _body}, acc ->
      MapSet.put(acc, {name, arity})
    end)
  end

  # Build `module_atom => MapSet({fn, arity})` map of every function
  # annotated with `@impl ...` in source. These are behaviour-callback
  # implementations reached via the framework's dispatch (e.g. `apply/3`
  # from Plug, ThousandIsland, GenServer) — invisible to static call-graph
  # analysis. Compiled-rule 6.24 (DeadCode) consumes this to skip
  # callback-impl findings; module-level rule 1.26 already covers the
  # module-level case via `Helpers.behaviour_implementor?`.
  defp compute_impl_annotated_functions(production_asts) do
    for {_file, ast} <- production_asts,
        module = AST.extract_module_name(ast),
        module != "Unknown",
        atom = AST.safe_existing_atom(module),
        not is_nil(atom),
        callbacks = AST.impl_callbacks(ast),
        MapSet.size(callbacks) > 0,
        into: %{},
        do: {atom, callbacks}
  end

  # Library carve-out: when mix.exs declares package/0 (Hex package), every
  # public module (not @moduledoc false) is part of the public API and
  # treated as anchored / "called from outside" — consumers we can't see
  # reach those modules. Returns a MapSet of module atoms or empty when
  # the project is not a library.
  defp compute_library_public_modules(production_asts, paths) do
    project_root =
      case paths do
        [path | _] -> path |> Path.expand() |> AST.find_mix_root()
        _ -> AST.find_mix_root(File.cwd!())
      end

    case AST.library?(project_root) do
      false ->
        MapSet.new()

      true ->
        for {_file, ast} <- production_asts,
            module = AST.extract_module_name(ast),
            module != "Unknown",
            not AST.internal_module?(ast),
            atom = AST.safe_existing_atom(module),
            not is_nil(atom),
            into: MapSet.new(),
            do: atom
    end
  end

  defp build_compiled_graph(paths) do
    project_root =
      case paths do
        [path | _] ->
          path
          |> Path.expand()
          |> find_project_root()

        _ ->
          File.cwd!()
      end

    Archdo.Compiled.analyze(project_root)
  end

  # MapSet of modules that have at least one incoming module-level edge
  # in the compiled graph. Built once per run to avoid O(N) lookups in
  # the rule-level cross-suppression check.
  defp compute_reached_modules(graph) do
    graph
    |> Archdo.Compiled.modules()
    |> Map.keys()
    |> Enum.filter(fn mod ->
      Archdo.Compiled.module_dependents(graph, mod) != []
    end)
    |> MapSet.new()
  end

  defp run_compiled_rules_with_graph(graph, opts) do
    Enum.flat_map(Rules.compiled_rules(), &safe_analyze_compiled(&1, graph, opts))
  end

  # Run a single compiled rule, isolating crashes so one broken rule doesn't block others.
  # Arity-aware dispatch: rules that opt into opts (e.g. 1.26 needs anchor data)
  # implement analyze_compiled/2; the rest stay on /1.
  defp safe_analyze_compiled(rule, graph, opts) do
    _ = Code.ensure_loaded(rule)

    case function_exported?(rule, :analyze_compiled, 2) do
      true -> rule.analyze_compiled(graph, opts)
      false -> rule.analyze_compiled(graph)
    end
  rescue
    e ->
      IO.puts(
        :standard_error,
        "[archdo] compiled rule #{rule.id()} crashed: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      []
  end

  @doc """
  Walk up from `path` looking for the closest ancestor directory containing
  a `mix.exs`. Returns that directory, or `File.cwd!/0` if no `mix.exs` is
  found before the filesystem root. Used by both the top-level facade and
  the Mix task to resolve the target project's root.
  """
  @spec find_project_root(String.t()) :: String.t()
  def find_project_root(path) do
    cond do
      File.exists?(Path.join(path, "mix.exs")) -> path
      path == "/" -> File.cwd!()
      true -> find_project_root(Path.dirname(path))
    end
  end

  # Project-level rule lists live on `Archdo.Rules` — see
  # `Rules.project_file_ast_rules/0`, `Rules.project_file_path_rules/0`,
  # and `Rules.project_rules/0` (the combined list used by `--list-packs`).

  defdelegate project_rules(), to: Rules

  defp run_project_arch_rules(paths, opts) do
    source_files = collect_files(paths)

    file_asts =
      for file <- source_files, {:ok, ast} <- [AST.parse_file(file)], do: {file, ast}

    # Detect library context once and thread via opts. Rules like
    # CE-30 (UnanchoredModule) need to know the project is a Hex
    # library (mix.exs has package/0) so public modules anchor by
    # virtue of being public API. find_mix_root walks up from a real
    # source-file path; works in production runs but unreliable in
    # unit tests with synthetic paths — hence the opts seam.
    opts = maybe_put_library(opts, source_files)

    file_ast_rules = filter_project_rules(Rules.project_file_ast_rules(), opts)
    file_path_rules = filter_project_rules(Rules.project_file_path_rules(), opts)

    file_ast_diagnostics =
      Enum.flat_map(file_ast_rules, &invoke_project_rule(&1, file_asts, opts))

    file_path_diagnostics =
      Enum.flat_map(file_path_rules, &invoke_project_path_rule(&1, source_files, opts))

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
      Enum.map(
        file_ast_diagnostics ++
          file_path_diagnostics ++
          metrics_diagnostics ++
          function_graph_diagnostics,
        &calibrate_project_diagnostic(&1, file_asts)
      )

    Runner.filter_diagnostics(all, opts)
  end

  # Project rules may take 1 or 2 args. Newer rules accept opts; older
  # rules don't. Dispatch by arity so existing rules keep working.
  # Wrapped in rescue so one broken rule doesn't block the rest.
  #
  # `Code.ensure_loaded` is critical: function_exported?/3 returns false
  # for any function on an unloaded module — without ensure_loaded we'd
  # always fall through to the /1 branch, silently dropping opts.
  # Honor `--packs` and `--only` / `--ignore` for project-level rules.
  # The phase1 / graph paths use Runner.filter_rules/2 already; this is
  # the missing pack filter for project rules that previously fired
  # unconditionally regardless of the user's pack selection.
  defp filter_project_rules(rules, opts) do
    packs =
      case Keyword.get(opts, :packs) do
        nil -> [:core]
        list when is_list(list) -> list
      end

    rules
    |> Runner.filter_rules_for_packs(packs)
    |> Runner.filter_rules_for_cleanup_pass(Keyword.get(opts, :cleanup_pass))
  end

  defp maybe_put_library(opts, []), do: opts

  defp maybe_put_library(opts, [first_file | _]) do
    case Keyword.has_key?(opts, :library?) do
      true -> opts
      false -> Keyword.put(opts, :library?, AST.library?(AST.find_mix_root(first_file)))
    end
  end

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

    source_asts = AST.parse_files(source_files)
    test_asts = AST.parse_files(test_files)

    IO.write(Runner.coverage_matrix_report(source_asts, test_asts))

    0
  end

  @doc """
  M-Aux4 audit: print modules + contexts that pass the Blackbox
  building-block verdict (every public function ≥ 0.9 possibility).
  """
  @spec print_building_blocks([String.t()]) :: non_neg_integer()
  def print_building_blocks(paths \\ ["lib"]) do
    file_asts = paths |> collect_files() |> AST.parse_files()
    {blocks, leaks, empty, total_with_api} = building_block_split(file_asts)

    print_audit_intro()
    print_modules_section(blocks, total_with_api)
    print_empty_modules_note(empty)
    print_contexts_section(file_asts)
    print_near_block_section(leaks)
    print_audit_summary(leaks)

    0
  end

  defp print_empty_modules_note([]), do: :ok

  defp print_empty_modules_note(empty) do
    IO.puts(
      "  (#{length(empty)} module(s) had no public functions to score — DSL " <>
        "configurations, behaviour declarations, or all-private helpers — " <>
        "excluded from the count)\n"
    )
  end

  defp building_block_split(file_asts) do
    module_results =
      file_asts
      |> Enum.map(fn {file, ast} ->
        {AST.extract_module_name(ast), file, ast, Archdo.Blackbox.module_verdict(ast)}
      end)
      |> Enum.reject(fn {module, _, _, _} -> module == "Unknown" end)

    # Three buckets:
    #   blocks:        :building_block — passed all checks
    #   empty:         :no_public_api  — DSL config, behaviour decl, etc.
    #                                    excluded from both counts.
    #   leaks:         {:leaks_at, _}  — failed at least one check
    blocks = Enum.filter(module_results, &(elem(&1, 3) == :building_block))
    empty = Enum.filter(module_results, &(elem(&1, 3) == :no_public_api))
    leaks = Enum.filter(module_results, &match?({:leaks_at, _}, elem(&1, 3)))

    # Total excludes :no_public_api modules — they had nothing to
    # demonstrate. The fraction "blocks of total" is meaningful only
    # when "total" means "modules with public API".
    total_with_api = length(blocks) + length(leaks)
    {blocks, leaks, empty, total_with_api}
  end

  defp print_audit_intro do
    IO.puts("\nArchdo — Building Block Audit (M-Aux4)\n")

    IO.puts(
      "Modules where EVERY public function scores ≥ 0.9 on the Blackbox\n" <>
        "possibility metric (input_closure × determinism × output_completeness ×\n" <>
        "totality × side_effect_free × errors_as_values).\n"
    )
  end

  defp print_modules_section(blocks, total) do
    IO.puts("─── Building-block MODULES (#{length(blocks)} of #{total}) ───\n")
    print_modules_list(blocks)
  end

  defp print_modules_list([]),
    do: IO.puts("  (none — likely missing @spec coverage; see --metrics for breakdown)\n")

  defp print_modules_list(list) do
    list
    |> Enum.map(fn {m, _, _, _} -> m end)
    |> Enum.sort()
    |> Enum.each(&IO.puts("  ✓ #{&1}"))

    IO.puts("")
  end

  defp print_contexts_section(file_asts) do
    contexts = collect_context_modules(file_asts)
    print_contexts_list(contexts, file_asts)
  end

  defp collect_context_modules(file_asts) do
    # A real context = a module file (lib/app/foo.ex) WITH a
    # corresponding directory (lib/app/foo/) holding sub-modules.
    # Mirrors rule 4.19's `context_facade?/2` heuristic: a leaf
    # module without a sub-namespace isn't a context. (Without this
    # filter, the audit listed every domain module as a "context"
    # with the awkward "leaks: Foo" output where Foo was the module
    # itself — validated against Oban.)
    dirs_with_children =
      file_asts
      |> Enum.map(fn {file, _} -> Path.dirname(file) end)
      |> MapSet.new()

    file_asts
    |> Enum.filter(fn {file, ast} ->
      Phoenix.classify_file(file, ast).layer == :context and
        String.ends_with?(file, ".ex") and
        MapSet.member?(dirs_with_children, Path.rootname(file))
    end)
    |> Enum.map(fn {file, ast} -> primary_module_name(file, ast) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # For files defining multiple modules (`lib/plug/upload.ex` defines
  # both `Plug.Upload` AND `Plug.UploadError`), `extract_module_name/1`
  # returns the FIRST defmodule encountered — which may not be the
  # file's primary module. Convention is that the file's rootname
  # implies the primary module name (`upload.ex` → `Plug.Upload`).
  # If that name is among the file's defined modules, prefer it.
  # Validated against Plug.
  defp primary_module_name(file, ast) do
    expected = filename_derived_module(file)

    case expected != nil and contains_module?(ast, expected) do
      true -> expected
      false -> AST.extract_module_name(ast)
    end
  end

  defp filename_derived_module(file) do
    case Regex.run(~r{(?:^|/)lib/(.+?)\.ex$}, file) do
      [_, path] ->
        path
        |> Path.split()
        |> Enum.map_join(".", &Macro.camelize/1)

      _ ->
        nil
    end
  end

  defp contains_module?(ast, module_name) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        node, true ->
          {node, true}

        {:defmodule, _, [{:__aliases__, _, aliases} | _]} = node, false ->
          name = aliases |> Module.concat() |> AST.module_name()
          {node, name == module_name}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp print_contexts_list([], _file_asts), do: :ok

  defp print_contexts_list(contexts, file_asts) do
    verdicts =
      Enum.map(contexts, fn ctx ->
        {ctx, Archdo.Blackbox.context_verdict(file_asts, ctx)}
      end)

    building_blocks = Enum.count(verdicts, fn {_, v} -> v == :building_block end)

    IO.puts("─── Building-block CONTEXTS (#{building_blocks} of #{length(contexts)}) ───\n")
    Enum.each(verdicts, &print_context_verdict/1)
    IO.puts("")
  end

  defp print_audit_summary(leaks) do
    IO.puts(
      "\nLeaks summary: #{length(leaks)} modules have at least one impure or " <>
        "spec-less public function."
    )
  end

  # M-Aux5: rank non-block modules by refactor distance (count of failed
  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # the verdict shape (:building_block vs {:leaks_at, modules}).
  defp print_context_verdict({ctx, :building_block}) do
    IO.puts("  ✓ #{ctx}")
  end

  defp print_context_verdict({ctx, {:leaks_at, modules}}) do
    preview = modules |> Enum.take(3) |> Enum.join(", ")
    IO.puts("  ✗ #{ctx} — leaks: #{preview}#{leak_overflow(length(modules))}")
  end

  defp leak_overflow(count) when count > 3, do: " (+#{count - 3} more)"
  defp leak_overflow(_count), do: ""

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

  @spec print_metrics_matrix([String.t()], keyword()) :: non_neg_integer()
  def print_metrics_matrix(paths \\ ["lib"], opts \\ []) do
    source_files = collect_files(paths)
    file_asts = AST.parse_files(source_files)

    graph = Graph.build(file_asts)
    metrics = Metrics.compute(graph, file_asts)

    metrics
    |> Enum.sort_by(& &1.distance, :desc)
    |> format_metrics_table()
    |> IO.write()

    print_quadrant_distributions(file_asts)
    print_blackbox_summary(file_asts)
    print_halstead_summary(file_asts)
    print_loc_summary(source_files)
    print_function_metrics_summary(file_asts)
    maybe_print_pagerank_summary(opts, paths)

    0
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatches on the
  # `--compiled` flag. PageRank requires the post-macro-expansion call
  # graph from compiled BEAMs; without that flag, the section is absent.
  defp maybe_print_pagerank_summary(opts, paths) do
    case Keyword.get(opts, :compiled, false) do
      true -> print_pagerank_summary(paths)
      false -> :ok
    end
  end

  defp print_pagerank_summary(paths) do
    case build_compiled_graph(paths) do
      {:ok, compiled_graph} ->
        do_print_pagerank(Centrality.page_rank(compiled_graph))
        do_print_degree(compiled_graph)
        do_print_betweenness(compiled_graph)
        do_print_closeness(compiled_graph)

      {:error, reason} ->
        IO.puts(:standard_error, "[archdo] pagerank: #{reason}")
    end
  end

  defp do_print_closeness(graph) do
    cl = Centrality.closeness(graph)

    IO.puts("\nArchdo — Closeness Centrality (compiled call graph)\n")
    IO.puts("Distance-based central functions — those near everything they")
    IO.puts("transitively call. Top 10 shown.\n")

    IO.puts(:io_lib.format("~-75ts ~12ts~n", ["Module.function/arity", "Closeness"]))
    IO.puts(String.duplicate("-", 92))

    cl
    |> Enum.sort_by(fn {_, v} -> -v end)
    |> Enum.take(10)
    |> Enum.each(fn {{mod, fun, arity}, v} ->
      label = "#{inspect(mod)}.#{fun}/#{arity}"
      IO.puts(:io_lib.format("~-75ts ~12.6f~n", [truncate(label, 75), v]))
    end)
  end

  defp do_print_betweenness(graph) do
    bc = Centrality.betweenness(graph)

    IO.puts("\nArchdo — Betweenness Centrality (compiled call graph)\n")
    IO.puts("Bridge / bottleneck functions — those lying on many shortest")
    IO.puts("paths between others. Top 10 shown.\n")

    IO.puts(:io_lib.format("~-75ts ~12ts~n", ["Module.function/arity", "Betweenness"]))
    IO.puts(String.duplicate("-", 92))

    bc
    |> Enum.sort_by(fn {_, v} -> -v end)
    |> Enum.take(10)
    |> Enum.each(fn {{mod, fun, arity}, v} ->
      label = "#{inspect(mod)}.#{fun}/#{arity}"
      IO.puts(:io_lib.format("~-75ts ~12.6f~n", [truncate(label, 75), v]))
    end)
  end

  defp do_print_degree(graph) do
    in_deg = Centrality.in_degree(graph)
    out_deg = Centrality.out_degree(graph)

    IO.puts("\nArchdo — Degree Centrality (compiled call graph)\n")
    print_degree_section("Top 10 by in-degree (most-called)", in_deg)
    print_degree_section("Top 10 by out-degree (highest fan-out)", out_deg)
  end

  defp print_degree_section(title, degree_map) do
    IO.puts("\n#{title}\n")
    IO.puts(:io_lib.format("~-75ts ~8ts~n", ["Module.function/arity", "degree"]))
    IO.puts(String.duplicate("-", 88))

    degree_map
    |> Enum.sort_by(fn {_, d} -> -d end)
    |> Enum.take(10)
    |> Enum.each(fn {{mod, fun, arity}, d} ->
      label = "#{inspect(mod)}.#{fun}/#{arity}"
      IO.puts(:io_lib.format("~-75ts ~8w~n", [truncate(label, 75), d]))
    end)
  end

  defp do_print_pagerank(ranks) when map_size(ranks) == 0, do: :ok

  defp do_print_pagerank(ranks) do
    IO.puts("\nArchdo — PageRank Centrality (compiled call graph)\n")

    IO.puts("Importance score — higher rank = more incoming references from")
    IO.puts("other functions (transitive). Top 30 shown.\n")

    IO.puts(:io_lib.format("~-75ts ~12ts~n", ["Module.function/arity", "PageRank"]))
    IO.puts(String.duplicate("-", 92))

    ranks
    |> Enum.sort_by(fn {_node, r} -> -r end)
    |> Enum.take(30)
    |> Enum.each(fn {{mod, fun, arity}, r} ->
      label = "#{inspect(mod)}.#{fun}/#{arity}"

      IO.puts(:io_lib.format("~-75ts ~12.6f~n", [truncate(label, 75), r]))
    end)

    IO.puts(:io_lib.format("\nTotal nodes ranked: ~w~n", [map_size(ranks)]))
  end

  defp print_function_metrics_summary([]), do: :ok

  defp print_function_metrics_summary(file_asts) do
    per_function =
      file_asts
      |> Enum.flat_map(fn {file, ast} ->
        Enum.map(FunctionMetrics.analyze(ast), fn m ->
          {AST.extract_module_name(ast), file, m}
        end)
      end)

    do_print_function_metrics(per_function)
  end

  defp do_print_function_metrics([]), do: :ok

  defp do_print_function_metrics(per_function) do
    IO.puts("\nArchdo — Function-Level Metrics\n")

    IO.puts("Per-function statement / return-point / local / parameter counts.")

    IO.puts("Top 20 by (statements + return_points) — high values flag candidates for review.\n")

    IO.puts(
      :io_lib.format("~-65ts ~6ts ~6ts ~6ts ~6ts~n", [
        "Module.function/arity",
        "stmts",
        "rets",
        "locals",
        "params"
      ])
    )

    IO.puts(String.duplicate("-", 96))

    per_function
    |> Enum.sort_by(fn {_, _, m} -> -(m.statements + m.return_points) end)
    |> Enum.take(20)
    |> Enum.each(fn {module, _file, m} ->
      label = "#{module || "?"}.#{m.name}/#{m.arity}"

      IO.puts(
        :io_lib.format("~-65ts ~6w ~6w ~6w ~6w~n", [
          truncate(label, 65),
          m.statements,
          m.return_points,
          m.locals,
          m.params
        ])
      )
    end)

    IO.puts(:io_lib.format("\nTotal functions analyzed: ~w~n", [length(per_function)]))
  end

  defp print_loc_summary([]), do: :ok

  defp print_loc_summary(files) do
    per_file = Enum.map(files, fn f -> {f, Loc.analyze(f)} end)

    {phys, log, cmt, blk} =
      Enum.reduce(per_file, {0, 0, 0, 0}, fn {_, l}, {p, lo, c, b} ->
        {p + l.physical, lo + l.logical, c + l.comments, b + l.blanks}
      end)

    IO.puts("\nArchdo — Source Line Counts\n")

    IO.puts("Per-file breakdown: physical = total lines; logical = top-level expressions")

    IO.puts("(def/defmodule/etc.); cmt = comment-only lines; blk = blank lines.\n")

    IO.puts(
      :io_lib.format("~-55ts ~8ts ~8ts ~8ts ~8ts~n", [
        "File",
        "phys",
        "log",
        "cmt",
        "blk"
      ])
    )

    IO.puts(String.duplicate("-", 92))

    per_file
    |> Enum.sort_by(fn {_, l} -> -l.physical end)
    |> Enum.take(20)
    |> Enum.each(fn {file, l} ->
      IO.puts(
        :io_lib.format("~-55ts ~8w ~8w ~8w ~8w~n", [
          truncate(Path.relative_to_cwd(file), 55),
          l.physical,
          l.logical,
          l.comments,
          l.blanks
        ])
      )
    end)

    IO.puts(
      :io_lib.format(
        "\nProject totals: phys = ~w, log = ~w, cmt = ~w, blk = ~w (top 20 of ~w files)~n",
        [phys, log, cmt, blk, length(per_file)]
      )
    )
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # the empty-list shape; reuses the Blackbox-section formatting
  # idiom rather than introducing a new control structure.
  defp print_halstead_summary([]), do: :ok

  defp print_halstead_summary(file_asts) do
    per_module =
      file_asts
      |> Enum.map(&module_halstead_entry/1)
      |> Enum.reject(&is_nil/1)

    do_print_halstead(per_module)
  end

  defp do_print_halstead([]), do: :ok

  defp do_print_halstead(per_module) do
    IO.puts("\nArchdo — Halstead Software-Science Metrics\n")

    IO.puts(
      "Per-module aggregate over all def/defp/defmacro bodies. Volume = length × log₂(vocab);"
    )

    IO.puts("Effort = volume × difficulty. Higher = more cognitive load to read or modify.\n")

    IO.puts(:io_lib.format("~-55ts ~10ts ~10ts ~10ts~n", ["Module", "Vocab", "Volume", "Effort"]))

    IO.puts(String.duplicate("-", 88))

    per_module
    |> Enum.sort_by(fn {_, _, h} -> -h.effort end)
    |> Enum.take(20)
    |> Enum.each(fn {module, _file, h} ->
      IO.puts(
        :io_lib.format("~-55ts ~10w ~10.1f ~10.1f~n", [
          truncate(module, 55),
          h.vocabulary,
          h.volume,
          h.effort
        ])
      )
    end)

    aggregate =
      Enum.reduce(per_module, {0.0, 0.0}, fn {_, _, h}, {v, e} ->
        {v + h.volume, e + h.effort}
      end)

    {total_v, total_e} = aggregate

    IO.puts(
      :io_lib.format(
        "\nProject totals: volume = ~.1f, effort = ~.1f (top 20 shown of ~w modules)~n",
        [total_v, total_e, length(per_module)]
      )
    )
  end

  defp module_halstead_entry({file, ast}) do
    case AST.extract_module_name(ast) do
      nil -> nil
      module -> {module, file, Halstead.analyze(ast)}
    end
  end

  # §§ elixir-planning: §6 — M25 Blackbox metric exposure. Per-module
  # blackbox possibility score + class distribution. Pure measurement;
  # no rule fires from these numbers (M26 will add CE-54/55/56 quadrant).
  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # the empty-list shape of scores. Function-head destructure
  # extracts file/ast directly — no separate `{file, ast} = pair`.
  defp module_blackbox_entry({file, ast}) do
    blackbox_entry_for(Archdo.Blackbox.score_module(ast), file, ast)
  end

  defp blackbox_entry_for([], _file, _ast), do: nil

  defp blackbox_entry_for(list, file, ast) do
    possibility =
      list |> Enum.map(fn {_, _, s, _} -> s end) |> Enum.sum() |> Kernel./(length(list))

    module = AST.extract_module_name(ast)
    {module, file, possibility, Archdo.Blackbox.classify(possibility)}
  end

  defp print_blackbox_summary(file_asts) do
    per_module =
      file_asts
      |> Enum.map(&module_blackbox_entry/1)
      |> Enum.reject(&is_nil/1)

    case per_module do
      [] ->
        :ok

      _ ->
        IO.puts("\nArchdo — Blackbox Possibility (Group O axis 1)\n")
        IO.puts("Per-module mean of (input_closure × determinism × output_completeness ×")
        IO.puts("totality × side_effect_free × errors_as_values).\n")

        IO.puts(:io_lib.format("~-55ts ~10ts ~-15ts~n", ["Module", "Possibility", "Class"]))

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
        dist = Enum.frequencies_by(per_module, fn {_, _, _, c} -> c end)
        IO.puts("\nClass distribution: #{inspect(dist)}\n")
    end
  end

  # §§ elixir-planning: §6 — Quadrant rules surface their cell distribution
  # alongside the Martin metrics table. Each registered quadrant rule
  # contributes a small per-cell count map, aggregated across analyzed
  # files. Empty section when no quadrant rules exist (current state until
  # CE-2/3 lands), so the column shape is in place from M14 onward.
  defp print_quadrant_distributions(file_asts) do
    rules = Quadrant.list_rules(Runner.phase1_rules() ++ Runner.graph_rules())

    print_quadrants(rules, file_asts)
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # the empty-rules-list shape.
  defp print_quadrants([], _file_asts), do: :ok

  defp print_quadrants(rules, file_asts) do
    IO.puts("\nArchdo — Quadrant Rule Cell Distributions\n")
    Enum.each(rules, &print_quadrant_for_rule(&1, file_asts))
  end

  defp print_quadrant_for_rule(rule, file_asts) do
    totals =
      Enum.reduce(file_asts, %{}, fn {file, ast}, acc ->
        rule
        |> Quadrant.distribution_for(file, ast, [])
        |> Map.merge(acc, fn _cell, a, b -> a + b end)
      end)

    IO.puts("  #{rule.id()} — #{rule.description()}")

    totals
    |> Enum.sort_by(fn {cell, _} -> inspect(cell) end)
    |> Enum.each(fn {cell, count} -> IO.puts("    #{inspect(cell)}: #{count}") end)

    IO.puts("")
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
