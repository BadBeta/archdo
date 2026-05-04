defmodule Archdo.Runner do
  @moduledoc """
  Project-wide rule runner. Owns the registered rule lists
  (delegated to `Archdo.Rules`), per-file analysis, graph-mode
  analysis, and the public `analyze/2` and `analyze_with_graph/2`
  entry points.

  Stable infrastructure: Mix tasks (`Mix.Tasks.Archdo`), the MCP tool
  surface, and `Archdo.run/2` all dispatch through this module. The
  rule-list shape and `analyze*` signatures are part of the public
  API surface.
  """

  # Reading source files for analysis IS the responsibility.
  Module.register_attribute(__MODULE__, :archdo_volatility, persist: true)
  @archdo_volatility :stable

  alias Archdo.{AST, Config, Diagnostic, FunctionGraph, Graph, Metrics, PluginCoverage, Rules}

  # §§ M-Plan7 — rules that consume project-level plug-coverage state.
  # The pre-pass only runs when at least one of these is enabled.
  @plug_coverage_consumers ["CE-27", "CE-28"]

  # §§ M-CG90 — rules that consume the project-level behaviour-callback
  # map (built by AST.collect_behaviour_callbacks/1). Lets per-file
  # rules resolve `@behaviour Foo` to Foo's callback set without
  # re-parsing every other file. The pre-pass only runs when at least
  # one of these is enabled.
  @behaviour_callbacks_consumers ["CE-54"]

  # The rule registries live on `Archdo.Rules` — `Rules.phase1_rules/0`
  # and `Rules.graph_rules/0`. Defdelegated here for the public API
  # callers (Mix tasks, MCP tools) that historically read these lists
  # off `Runner`.

  defdelegate phase1_rules(), to: Rules
  defdelegate graph_rules(), to: Rules

  @doc """
  Analyze files with per-file rules (Phase 1).
  """
  @spec analyze([String.t()], keyword()) :: [Archdo.Diagnostic.t()]
  def analyze(files, opts \\ []) do
    base_rules = Keyword.get(opts, :rules, Rules.phase1_rules())
    enabled_rules = filter_rules(base_rules, opts)

    # §§ elixir-planning: §9.1 — runner pre-pass for project-level
    # plug-coverage state. Threaded through opts so per-file rules
    # consume it like any other context. Skipped when no consuming
    # rule is enabled (saves the parse) or when caller pre-supplied
    # the index (test seam + composition with analyze_with_graph/2).
    opts = maybe_compute_plug_coverage(opts, files, enabled_rules)
    opts = maybe_compute_behaviour_callbacks(opts, files, enabled_rules)

    files
    |> Task.async_stream(
      fn file -> analyze_file(file, enabled_rules, opts) end,
      ordered: false,
      timeout: 30_000
    )
    |> Enum.flat_map(fn
      {:ok, diagnostics} ->
        diagnostics

      {:exit, reason} ->
        IO.puts(:standard_error, "[archdo] file analysis crashed: #{inspect(reason)}")
        []
    end)
    |> sort_diagnostics()
  end

  # §§ M-Plan19 Phase 3 follow-up — project-level rule dispatchers
  # moved here from `Archdo` top-level. Runner is the rule executor;
  # external orchestration (Archdo) calls these instead of importing
  # individual rule modules. Closes the Rules-context boundary leak
  # for these 9 rule modules.

  @doc """
  Run module-level metrics rules (currently MainSequenceDistance).
  Returns project-level diagnostics from the metrics graph.
  """
  @spec run_metrics_rules([{String.t(), Macro.t()}]) :: [Archdo.Diagnostic.t()]
  def run_metrics_rules(file_asts) do
    graph = Graph.build(file_asts)
    metrics = Metrics.compute(graph, file_asts)
    file_map = AST.module_file_map(file_asts)

    Rules.main_sequence_distance(metrics, file_map)
  end

  @doc """
  Run function-graph rules (boundary, fan-out, fan-in, feature-envy,
  chatty-boundary, sync-context-coupling). Some rules require a
  populated `contexts` config; they no-op when none are configured.
  """
  @spec run_function_graph_rules([{String.t(), Macro.t()}], keyword()) ::
          [Archdo.Diagnostic.t()]
  def run_function_graph_rules(file_asts, _opts) do
    config = Config.load()
    fn_graph = FunctionGraph.build(file_asts)

    contexts = config.contexts

    boundary_diagnostics =
      case contexts do
        [_ | _] -> Rules.function_boundary(fn_graph, contexts)
        [] -> []
      end

    fan_out_diagnostics = Rules.function_fan_out(fn_graph)
    fan_in_diagnostics = Rules.shotgun_surgery(fn_graph)
    feature_envy_diagnostics = Rules.feature_envy(fn_graph)

    chatty_diagnostics =
      case contexts do
        [_ | _] -> Rules.chatty_boundary(fn_graph, contexts)
        [] -> []
      end

    sync_coupling_diagnostics =
      case contexts do
        [_ | _] -> Rules.sync_context_coupling(fn_graph, contexts)
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
  Run test-project rules (TestMirrorsSource, CoverageGap). Filters
  by opts at the end so callers don't need to know which diagnostics
  are emitted.
  """
  @spec run_test_project_rules([String.t()], [String.t()], keyword()) ::
          [Archdo.Diagnostic.t()]
  def run_test_project_rules(source_files, test_files, opts) do
    mirror_diagnostics = Rules.test_mirrors_source(source_files, test_files)

    source_asts = AST.parse_files(source_files)
    test_asts = AST.parse_files(test_files)
    coverage_diagnostics = Rules.coverage_gap(source_asts ++ test_asts)

    filter_diagnostics(mirror_diagnostics ++ coverage_diagnostics, opts)
  end

  @doc """
  Render the test coverage gap matrix as a printable report. Wraps
  the underlying CoverageGap rule so callers don't need to alias it.
  """
  @spec coverage_matrix_report([{String.t(), Macro.t()}], [{String.t(), Macro.t()}]) ::
          iodata()
  def coverage_matrix_report(source_asts, test_asts) do
    Rules.coverage_matrix_report(source_asts ++ test_asts)
  end

  @doc """
  Filter a diagnostic list by `:ignore` (rule_id list) and `:only` (rule_id
  list) options. Public so the top-level `Archdo` facade can reuse the
  exact same filter without redefining it.
  """
  @spec filter_diagnostics([Archdo.Diagnostic.t()], keyword()) :: [Archdo.Diagnostic.t()]
  def filter_diagnostics(diagnostics, opts) do
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
  Analyze files with both per-file rules AND graph-based boundary rules (Phase 2).
  """
  @spec analyze_with_graph([String.t()], keyword()) :: [Archdo.Diagnostic.t()]
  def analyze_with_graph(files, opts \\ []) do
    # Phase 1: per-file analysis
    per_file_diagnostics = analyze(files, opts)

    # Phase 2: build graph and run boundary rules
    config = Keyword.get_lazy(opts, :config, fn -> Config.load() end)
    graph_diagnostics = run_graph_rules(files, config, opts)

    sort_diagnostics(per_file_diagnostics ++ graph_diagnostics)
  end

  defp run_graph_rules(files, config, opts) do
    enabled_rules = filter_rules(Rules.graph_rules(), opts)

    if enabled_rules == [] do
      []
    else
      # Parse all files and build the graph
      file_asts =
        for file <- files, {:ok, ast} <- [AST.parse_file(file)], do: {file, ast}

      graph = Graph.build(file_asts)

      enabled_rules
      |> Enum.flat_map(&run_graph_rule(&1, graph, config))
      |> Enum.map(&Archdo.Severity.adjust_diagnostic(&1, nil))
    end
  end

  # §§ elixir-implementing: §2.1 — boolean (function_exported?) →
  # multi-clause head dispatching on the predicate result.
  defp run_graph_rule(rule, graph, config) do
    invoke_graph_rule(function_exported?(rule, :analyze_graph, 2), rule, graph, config)
  end

  defp invoke_graph_rule(false, _rule, _graph, _config), do: []
  defp invoke_graph_rule(true, rule, graph, config), do: rule.analyze_graph(graph, config)

  defp maybe_compute_plug_coverage(opts, files, enabled_rules) do
    cond do
      Keyword.has_key?(opts, :plug_coverage) ->
        opts

      not plug_coverage_needed?(enabled_rules) ->
        opts

      true ->
        file_asts = AST.parse_files(files)
        Keyword.put(opts, :plug_coverage, PluginCoverage.scan(file_asts))
    end
  end

  defp plug_coverage_needed?(rules) do
    Enum.any?(rules, fn rule -> rule.id() in @plug_coverage_consumers end)
  end

  defp maybe_compute_behaviour_callbacks(opts, files, enabled_rules) do
    cond do
      Keyword.has_key?(opts, :behaviour_callbacks) ->
        opts

      not behaviour_callbacks_needed?(enabled_rules) ->
        opts

      true ->
        file_asts = AST.parse_files(files)
        Keyword.put(opts, :behaviour_callbacks, AST.collect_behaviour_callbacks(file_asts))
    end
  end

  defp behaviour_callbacks_needed?(rules) do
    Enum.any?(rules, fn rule -> rule.id() in @behaviour_callbacks_consumers end)
  end

  defp analyze_file(file, rules, opts) do
    case AST.parse_file(file) do
      {:ok, ast} ->
        # §§ elixir-planning: §6 — classify once, reuse across rules.
        # Phoenix lens decides "what kind of file is this?" (operational /
        # web / context / ...). Volatility lens decides "what kind of
        # dependencies does it have?". Both threaded into rule opts.
        phoenix = Archdo.Phoenix.classify_file(file, ast)
        volatility = Archdo.Volatility.classify_module(file, ast, opts)

        opts =
          opts
          |> Keyword.put(:phoenix, phoenix)
          |> Keyword.put(:volatility, volatility)

        rules
        |> Enum.flat_map(&safe_analyze(&1, file, ast, opts))
        |> Enum.map(&Archdo.Severity.adjust_diagnostic(&1, phoenix))
        |> filter_suppressed(file)

      {:error, _reason} ->
        []
    end
  end

  # Filter out diagnostics suppressed by `# archdo:allow RULE_ID` comments
  # on the line immediately before the finding.
  defp filter_suppressed(diagnostics, file) do
    case File.read(file) do
      {:ok, content} ->
        lines = String.split(content, "\n")

        Enum.reject(diagnostics, fn d ->
          prev_line = Enum.at(lines, max(d.line - 2, 0), "")

          String.contains?(prev_line, "archdo:allow") and
            (String.contains?(prev_line, d.rule_id) or String.contains?(prev_line, "all"))
        end)

      {:error, _} ->
        diagnostics
    end
  end

  # Run a single rule, isolating crashes so one broken rule doesn't block others.
  # A rule crash is a bug in Archdo, not in the analyzed code — log visibly and continue.
  # Project-only rules (`analyze_project/N` / `analyze_compiled/N`) skip
  # the per-file path entirely — `analyze/3` is optional in the behaviour.
  # `Code.ensure_loaded/1` first because `function_exported?/3` returns
  # `false` for modules not yet loaded into the runtime.
  defp safe_analyze(rule, file, ast, opts) do
    _ = Code.ensure_loaded(rule)

    case function_exported?(rule, :analyze, 3) do
      true -> rule.analyze(file, ast, opts)
      false -> []
    end
  rescue
    e ->
      IO.puts(
        :standard_error,
        "[archdo] rule #{rule.id()} crashed on #{file}: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      []
  end

  defp filter_rules(rules, opts) do
    rules
    |> filter_rules_for_packs(packs_from_opts(opts))
    |> filter_rules_for_cleanup_pass(Keyword.get(opts, :cleanup_pass))
    |> apply_only_ignore(opts)
  end

  @doc """
  Filter `rules` to those tagged with the given cleanup-guide pass
  (1..14). When `pass` is `nil`, returns the input unchanged. When
  `pass` is an integer outside 1..14 (or no rule matches), returns `[]`.

  Public so tests can exercise it without the runner pipeline.
  """
  @spec filter_rules_for_cleanup_pass([module()], integer() | nil) :: [module()]
  def filter_rules_for_cleanup_pass(rules, nil) when is_list(rules), do: rules

  def filter_rules_for_cleanup_pass(rules, pass)
      when is_list(rules) and is_integer(pass) do
    Archdo.CleanupPass.rules_for(pass, rules)
  end

  defp apply_only_ignore(rules, opts) do
    case Keyword.get(opts, :only) do
      nil ->
        case Keyword.get(opts, :ignore) do
          nil -> rules
          ids -> Enum.reject(rules, &(&1.id() in ids))
        end

      ids ->
        Enum.filter(rules, &(&1.id() in ids))
    end
  end

  # §§ elixir-planning: §6 — Pack abstraction (M13). Filters the rule list to
  # rules whose declared `@pack` is in `enabled_packs`. Rules without a
  # `pack/0` callback default to `:core` via `Archdo.Rule.pack_of/1`.
  @doc """
  Filter `rules` to those whose pack is in `enabled_packs`.

  Public so tests can exercise it without the runner pipeline; called
  internally from `filter_rules/2`.
  """
  @spec filter_rules_for_packs([module()], [Archdo.Rule.pack()]) :: [module()]
  def filter_rules_for_packs(rules, enabled_packs) when is_list(enabled_packs) do
    enabled_set = MapSet.new(enabled_packs)
    Enum.filter(rules, &MapSet.member?(enabled_set, Archdo.Rule.pack_of!(&1)))
  end

  defp packs_from_opts(opts) do
    case Keyword.get(opts, :packs) do
      nil -> [:core]
      list when is_list(list) -> list
    end
  end

  defp sort_diagnostics(diagnostics) do
    Enum.sort_by(diagnostics, fn d -> {Diagnostic.severity_order(d.severity), d.file, d.line} end)
  end
end
