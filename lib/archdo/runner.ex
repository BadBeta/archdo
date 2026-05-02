defmodule Archdo.Runner do
  @moduledoc false

  alias Archdo.{AST, Config, Diagnostic, Graph, PluginCoverage}

  # §§ M-Plan7 — rules that consume project-level plug-coverage state.
  # The pre-pass only runs when at least one of these is enabled.
  @plug_coverage_consumers ["CE-27", "CE-28"]

  @phase1_rules [
    # OTP rules
    Archdo.Rules.OTP.UnsupervisedProcess,
    Archdo.Rules.OTP.BlockingInit,
    Archdo.Rules.OTP.BlockingCallback,
    Archdo.Rules.OTP.ReceiveInCallback,
    Archdo.Rules.OTP.SendSelfInInit,
    Archdo.Rules.OTP.SilentCatchAll,
    Archdo.Rules.OTP.TimeoutAsPolling,
    Archdo.Rules.OTP.ScatteredGenserverCall,
    Archdo.Rules.OTP.SpawnWithoutLink,
    Archdo.Rules.OTP.TaskAsyncWithoutAwait,
    Archdo.Rules.OTP.UnsupervisedTask,
    Archdo.Rules.OTP.DynamicAtomName,
    Archdo.Rules.OTP.GlobalRegistration,
    Archdo.Rules.OTP.ProcessSleep,
    Archdo.Rules.OTP.MaxRestarts,
    Archdo.Rules.OTP.MissingTerminate,
    Archdo.Rules.OTP.CastForCall,
    Archdo.Rules.OTP.MonitorWithoutHandler,
    Archdo.Rules.OTP.FlatSupervision,
    Archdo.Rules.OTP.EtsNoHeir,
    Archdo.Rules.OTP.SyncCallChains,
    Archdo.Rules.OTP.LargeMessages,
    Archdo.Rules.OTP.UnnecessaryProcess,
    Archdo.Rules.OTP.SingletonBottleneck,
    Archdo.Rules.OTP.UnboundedState,
    Archdo.Rules.OTP.CustomRegistry,
    Archdo.Rules.OTP.AgentMisuse,
    Archdo.Rules.OTP.EtsAsBus,
    Archdo.Rules.OTP.RestartTypeMismatch,
    Archdo.Rules.OTP.ProcessDictionary,
    Archdo.Rules.OTP.UnnamedSingleton,
    Archdo.Rules.OTP.UnsafeTracing,
    Archdo.Rules.OTP.GenstageNoDemand,
    Archdo.Rules.OTP.StalePidReference,
    Archdo.Rules.OTP.MissingHandleInfo,
    Archdo.Rules.OTP.CallSelfDeadlock,
    Archdo.Rules.OTP.BrutalKill,
    Archdo.Rules.OTP.EtsOwnershipLeak,
    Archdo.Rules.OTP.HardcodedCallTimeout,
    Archdo.Rules.OTP.CallbackSprawl,
    Archdo.Rules.OTP.AtomInHotPath,
    Archdo.Rules.OTP.EtsWithoutCleanup,
    # Module quality rules
    Archdo.Rules.Module.MissingModuledoc,
    Archdo.Rules.Module.MissingSpec,
    Archdo.Rules.Module.FunctionComplexity,
    Archdo.Rules.Module.StructFieldCount,
    Archdo.Rules.Module.BehaviourSize,
    Archdo.Rules.Module.ModuleCohesion,
    Archdo.Rules.Module.ExternalDepsNoBehaviour,
    Archdo.Rules.Module.ScatteredConfig,
    Archdo.Rules.Module.LibConfigViaArgs,
    Archdo.Rules.Module.TypeDispatch,
    Archdo.Rules.Module.CrossCuttingInDomain,
    Archdo.Rules.Module.ModuleLength,
    Archdo.Rules.Module.TimeInjection,
    Archdo.Rules.Module.PrimitiveObsession,
    Archdo.Rules.Module.BooleanFlagArgs,
    Archdo.Rules.Module.PretentiousName,
    Archdo.Rules.Module.MixedConcerns,
    Archdo.Rules.Module.NaturalSeams,
    Archdo.Rules.Module.ResponsibilityClustering,
    Archdo.Rules.Module.ReinventedPubSub,
    Archdo.Rules.Module.ReinventedEnumerable,
    Archdo.Rules.Module.RescueSwallowsError,
    Archdo.Rules.Module.RaiseInNonBang,
    Archdo.Rules.Module.InconsistentErrorShape,
    Archdo.Rules.Module.RescueForExpected,
    Archdo.Rules.Module.BangInOkErrorFunction,
    Archdo.Rules.Module.MissingRescueAtBoundary,
    Archdo.Rules.Module.NestingDepth,
    Archdo.Rules.Module.ExceptionLaundering,
    Archdo.Rules.Module.IfElseDispatch,
    Archdo.Rules.Module.NonTailRecursion,
    Archdo.Rules.Module.UnnecessaryRecursion,
    Archdo.Rules.Module.BrokenTailRecursion,
    Archdo.Rules.Module.UnboundedRecursion,
    Archdo.Rules.Module.StubFunction,
    Archdo.Rules.Module.UnreachableClause,
    Archdo.Rules.Module.ShadowedClause,
    Archdo.Rules.Module.ConstantExpression,
    Archdo.Rules.Module.DefensiveNilReturn,
    Archdo.Rules.Module.SequentialWhereParallel,
    Archdo.Rules.Module.BuriedRescue,
    Archdo.Rules.Module.CodeSlop,
    Archdo.Rules.Module.IdentityTransformation,
    Archdo.Rules.Module.RedundantGuardRecheck,
    Archdo.Rules.Module.VerboseOkUnwrap,
    Archdo.Rules.Module.DeadPrivateFunction,
    Archdo.Rules.Module.SingleClauseWith,
    Archdo.Rules.Module.LongParameterList,
    Archdo.Rules.Module.NestedControlFlow,
    Archdo.Rules.Module.BooleanBlindness,
    Archdo.Rules.Module.StringConcatInLoop,
    Archdo.Rules.Module.EnumCountEmptyCheck,
    Archdo.Rules.Module.MapKeysLength,
    Archdo.Rules.Module.RegexInLoop,
    Archdo.Rules.Module.InefficientListOperation,
    Archdo.Rules.Module.CollectionPerf,
    Archdo.Rules.Module.EagerEvaluation,
    Archdo.Rules.Module.SensitiveDataExposure,
    Archdo.Rules.Module.StringLengthCheck,
    Archdo.Rules.Module.KeywordLookupInLoop,
    Archdo.Rules.Boundary.DevDepInProd,
    Archdo.Rules.Boundary.UmbrellaDepConsistency,
    Archdo.Rules.Boundary.UnusedAlias,
    Archdo.Rules.Boundary.UntypedBoundary,
    # NIF rules
    Archdo.Rules.NIF.NifPanic,
    Archdo.Rules.NIF.NifBehindBehaviour,
    Archdo.Rules.NIF.NifSchedulerSafety,
    Archdo.Rules.NIF.PortVsNif,
    # Event sourcing rules
    Archdo.Rules.EventSourcing.CommandEventNaming,
    Archdo.Rules.EventSourcing.PureAggregateApply,
    Archdo.Rules.EventSourcing.ImmutableEvents,
    Archdo.Rules.EventSourcing.EventsNeedJasonEncoder,
    Archdo.Rules.EventSourcing.ProjectorReadsExternal,
    Archdo.Rules.EventSourcing.ProcessManagerReadsProjection,
    Archdo.Rules.EventSourcing.AggregateMissingBehaviour,
    # State machine rules
    Archdo.Rules.StateMachine.ImplicitBooleanState,
    Archdo.Rules.StateMachine.StateReachability,
    Archdo.Rules.StateMachine.TerminalStateIntegrity,
    Archdo.Rules.StateMachine.UndeclaredNextState,
    Archdo.Rules.StateMachine.StateAssignOutsideSet,
    Archdo.Rules.StateMachine.IncompleteStateMatch,
    # Testing rules
    Archdo.Rules.Testing.MocksNeedBehaviours,
    Archdo.Rules.Testing.RepoInTests,
    Archdo.Rules.Testing.AsyncEligibility,
    Archdo.Rules.Testing.SleepInTests,
    Archdo.Rules.Testing.TestNaming,
    Archdo.Rules.Testing.NoAssertion,
    Archdo.Rules.Testing.TrivialAssertion,
    Archdo.Rules.Testing.LongSetup,
    Archdo.Rules.Testing.LongTest,
    Archdo.Rules.Testing.MocksNotVerified,
    Archdo.Rules.Testing.MockingOwnModules,
    Archdo.Rules.Testing.RuntimeConfigForDi,
    Archdo.Rules.Testing.GenericTestNames,
    Archdo.Rules.Testing.WeakAssertion,
    Archdo.Rules.Testing.MissingTestCleanup,
    Archdo.Rules.Testing.HardcodedTestData,
    Archdo.Rules.Testing.MissingErrorPath,
    Archdo.Rules.Testing.OverMocking,
    Archdo.Rules.Testing.EmptyDescribe,
    Archdo.Rules.Testing.UntestedModule,
    Archdo.Rules.Testing.ProcessLeak,
    Archdo.Rules.Testing.AssertOnImplementation,
    Archdo.Rules.Testing.FlakyTestIndicators,
    # Composition rules
    Archdo.Rules.Composition.ShallowUse,
    Archdo.Rules.Composition.NamespaceDepth,
    # Per-file boundary rules
    Archdo.Rules.Boundary.ImportBreadth,
    Archdo.Rules.Boundary.UnusedDependency,
    Archdo.Rules.Boundary.UnvalidatedParams,
    Archdo.Rules.Boundary.LogicInController,
    Archdo.Rules.Boundary.LargeLiveviewAssigns,
    Archdo.Rules.Boundary.LogicInLiveview,
    Archdo.Rules.Boundary.PreloadInLoop,
    Archdo.Rules.Boundary.PubsubWithoutHandler,
    Archdo.Rules.Boundary.ReverseDependency,
    Archdo.Rules.Boundary.QueryInInterface,
    Archdo.Rules.Boundary.CrossContextSchema,
    Archdo.Rules.Boundary.DirectProcessCall,
    Archdo.Rules.Boundary.CrossContextConfig,
    # Resilience rules
    Archdo.Rules.Module.UnprotectedExternalCall,
    Archdo.Rules.Module.UnboundedExternalCall,
    # Change Economy rules (file-level)
    Archdo.Rules.CE.CatchAllRescue,
    Archdo.Rules.CE.OkLosesInfo,
    Archdo.Rules.CE.AcquireRelease,
    Archdo.Rules.CE.HardcodedVolatileDeps,
    Archdo.Rules.CE.MixedModuleSplit,
    Archdo.Rules.CE.VolatileCallNoTimeout,
    Archdo.Rules.CE.VolatileNoRetry,
    Archdo.Rules.CE.HighCognitiveComplexity,
    Archdo.Rules.CE.ComplexityShape,
    Archdo.Rules.CE.BlackboxQuadrant,
    Archdo.Rules.CE.CrossCuttingDensity,
    Archdo.Rules.CE.ErrorPathWithoutLog,
    Archdo.Rules.CE.OpaqueProcessState,
    Archdo.Rules.CE.BoundaryTelemetry,
    Archdo.Rules.CE.EffectLeak,
    Archdo.Rules.CE.UnguardedBuildingBlock
  ]

  @graph_rules [
    Archdo.Rules.Boundary.DependencyDirection,
    Archdo.Rules.Boundary.FrameworkInDomain,
    Archdo.Rules.Boundary.ContextEncapsulation,
    Archdo.Rules.Boundary.CircularDependencies,
    Archdo.Rules.Boundary.RepoInInterface,
    Archdo.Rules.EventSourcing.SharedProjections
  ]

  @doc """
  Returns the list of per-file rule modules.
  Useful for tooling that wants to enumerate rules without invoking the runner.
  """
  @spec phase1_rules() :: [module()]
  def phase1_rules, do: @phase1_rules

  @doc """
  Returns the list of cross-file (graph) rule modules.
  """
  @spec graph_rules() :: [module()]
  def graph_rules, do: @graph_rules

  @doc """
  Analyze files with per-file rules (Phase 1).
  """
  @spec analyze([String.t()], keyword()) :: [Archdo.Diagnostic.t()]
  def analyze(files, opts \\ []) do
    base_rules = Keyword.get(opts, :rules, @phase1_rules)
    enabled_rules = filter_rules(base_rules, opts)

    # §§ elixir-planning: §9.1 — runner pre-pass for project-level
    # plug-coverage state. Threaded through opts so per-file rules
    # consume it like any other context. Skipped when no consuming
    # rule is enabled (saves the parse) or when caller pre-supplied
    # the index (test seam + composition with analyze_with_graph/2).
    opts = maybe_compute_plug_coverage(opts, files, enabled_rules)

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
    enabled_rules = filter_rules(@graph_rules, opts)

    if enabled_rules == [] do
      []
    else
      # Parse all files and build the graph
      file_asts =
        for file <- files, {:ok, ast} <- [AST.parse_file(file)], do: {file, ast}

      graph = Graph.build(file_asts)

      enabled_rules
      |> Enum.flat_map(fn rule ->
        case function_exported?(rule, :analyze_graph, 2) do
          true -> rule.analyze_graph(graph, config)
          false -> []
        end
      end)
      |> Enum.map(&Archdo.Severity.adjust_diagnostic(&1, nil))
    end
  end

  defp maybe_compute_plug_coverage(opts, files, enabled_rules) do
    cond do
      Keyword.has_key?(opts, :plug_coverage) ->
        opts

      not plug_coverage_needed?(enabled_rules) ->
        opts

      true ->
        file_asts = parse_for_pre_pass(files)
        Keyword.put(opts, :plug_coverage, PluginCoverage.scan(file_asts))
    end
  end

  defp plug_coverage_needed?(rules) do
    Enum.any?(rules, fn rule -> rule.id() in @plug_coverage_consumers end)
  end

  defp parse_for_pre_pass(files) do
    for file <- files, {:ok, ast} <- [AST.parse_file(file)], do: {file, ast}
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
  defp safe_analyze(rule, file, ast, opts) do
    rule.analyze(file, ast, opts)
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
    |> apply_only_ignore(opts)
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
    Enum.filter(rules, &MapSet.member?(enabled_set, Archdo.Rule.pack_of(&1)))
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
