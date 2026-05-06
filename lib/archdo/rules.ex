defmodule Archdo.Rules do
  @moduledoc """
  Project-wide rules registry and execution facade.

  Owns the rule-list attributes (`phase1`, `graph`, `compiled`,
  `project_file_ast`, `project_file_path`) plus the defdelegate
  entry points for individual rules that need direct invocation
  from outside the runner. Every external orchestrator (Runner, Mix
  tasks, MCP tools, `Archdo` itself) reaches `Archdo.Rules.*` rule
  modules ONLY through this facade — direct aliases of internal
  rule modules from outside this file are boundary leaks per rule
  1.2 (`reach into context internals`).
  """

  alias Archdo.Rules.Boundary.{
    ChattyBoundary,
    FunctionBoundary,
    ShotgunSurgery,
    SyncContextCoupling
  }

  alias Archdo.Rules.Module.{FeatureEnvy, FunctionFanOut, MainSequenceDistance}
  alias Archdo.Rules.Testing.{CoverageGap, TestMirrorsSource}

  # --- Per-file rule registry ---

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
    Archdo.Rules.OTP.AsyncDropsLoggerMetadata,
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
    Archdo.Rules.OTP.MissingTelemetryObanWorker,
    Archdo.Rules.OTP.MissingHandleAsync,
    Archdo.Rules.OTP.MissingTelemetryLiveViewMount,
    Archdo.Rules.OTP.GenServerCallNoExitCatch,
    Archdo.Rules.OTP.MissingImplOnKnownCallback,
    Archdo.Rules.OTP.HandleContinueOpportunity,
    Archdo.Rules.OTP.SensitiveStateNoFormatStatus,
    Archdo.Rules.OTP.TaskAsyncInGenServer,
    Archdo.Rules.OTP.RegistryDynSupOneForOne,
    Archdo.Rules.OTP.ObanWorkerWithoutUnique,
    Archdo.Rules.OTP.ObanWorkerWithoutMaxAttempts,
    Archdo.Rules.OTP.GenServerCounterIncrementCall,
    Archdo.Rules.OTP.SendAfterSelfTickLoop,
    Archdo.Rules.OTP.ApplicationGetEnvInCallback,
    Archdo.Rules.OTP.GenTcpActiveTrue,
    Archdo.Rules.OTP.GenTcpRecvNoTimeout,
    Archdo.Rules.OTP.AtomInHotPath,
    Archdo.Rules.OTP.EtsWithoutCleanup,
    Archdo.Rules.OTP.DetsOrderedSet,
    Archdo.Rules.OTP.DetsOwnershipLeak,
    Archdo.Rules.OTP.InlineEffectInBuildingBlock,
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
    Archdo.Rules.Module.InefficientFilter,
    Archdo.Rules.Module.TelemetryInRecursiveFunction,
    Archdo.Rules.Module.CallbackHell,
    Archdo.Rules.Module.ReduceWithThrowCatch,
    Archdo.Rules.Module.CondWithoutCatchall,
    Archdo.Rules.Module.PipesOnOneLine,
    Archdo.Rules.Module.ThenOpportunity,
    Archdo.Rules.Module.TapOpportunity,
    Archdo.Rules.Module.ZipMapAsZipWith,
    Archdo.Rules.Module.GroupByMapSize,
    Archdo.Rules.Module.SplitWithOpportunity,
    Archdo.Rules.Module.FindThenTransform,
    Archdo.Rules.Module.MapFlatten,
    Archdo.Rules.Module.MapToMapSet,
    Archdo.Rules.Module.EmptyMapPatternMatchesAny,
    Archdo.Rules.Module.MapHasKeyThenGet,
    Archdo.Rules.Module.RepeatedGuardChain,
    Archdo.Rules.Module.FilterMatchToForPattern,
    Archdo.Rules.Module.BoundaryAtomStringMismatch,
    Archdo.Rules.Module.WholeStructOneField,
    Archdo.Rules.Module.BodyGuardOpportunity,
    Archdo.Rules.Module.TryRescueSafeAlternative,
    Archdo.Rules.Module.InsecureSecretCompare,
    Archdo.Rules.Module.SilentRescue,
    Archdo.Rules.Module.MapPutChainAsMerge,
    Archdo.Rules.Module.MapUpdateOpportunity,
    Archdo.Rules.Module.KeywordValidateOpportunity,
    Archdo.Rules.Module.JasonDecodeWithAtomKeys,
    Archdo.Rules.Module.NonLazyLoggerInspect,
    Archdo.Rules.Module.DefdelegateOpportunity,
    Archdo.Rules.Module.DocFalseShouldBeDefp,
    Archdo.Rules.Module.ManualTaskAwaitList,
    Archdo.Rules.Module.CollectionPerf,
    Archdo.Rules.Module.EagerEvaluation,
    Archdo.Rules.Module.SensitiveDataExposure,
    Archdo.Rules.Module.UnsafeDeserialization,
    Archdo.Rules.Module.DynamicApplyFromInput,
    Archdo.Rules.Module.StacktraceInResponse,
    Archdo.Rules.Module.IoInspectInLib,
    Archdo.Rules.Module.SecretStructInspect,
    Archdo.Rules.Module.StringLengthCheck,
    Archdo.Rules.Module.KeywordLookupInLoop,
    Archdo.Rules.Module.ModelsServicesHelpersDir,
    Archdo.Rules.Module.PredicateMissingQuestionMark,
    Archdo.Rules.Module.BangPairInconsistency,
    Archdo.Rules.Module.CircuitBreakerInContextModule,
    Archdo.Rules.Module.SystemTimeForDuration,
    Archdo.Rules.Module.ParseInEnumLambda,
    Archdo.Rules.Module.EnumIntoMapAsMapNew,
    Archdo.Rules.Module.EctoFragmentStringInterpolation,
    Archdo.Rules.Module.CodeEvalStringOrQuoted,
    Archdo.Rules.Module.HandRolledTokenCrypto,
    Archdo.Rules.Module.ShortCircuitOverAccumulating,
    Archdo.Rules.Module.ResultMapOpportunity,
    Archdo.Rules.Module.PipeSubjectPosition,
    Archdo.Rules.Module.NestedMapUpdateAsUpdateIn,
    Archdo.Rules.Boundary.DevDepInProd,
    Archdo.Rules.Boundary.UmbrellaDepConsistency,
    Archdo.Rules.Boundary.UnusedAlias,
    Archdo.Rules.Boundary.UntypedBoundary,
    Archdo.Rules.Boundary.MissingTelemetryAuthPlug,
    Archdo.Rules.Boundary.MissingTelemetryHttpAdapter,
    # NIF rules
    Archdo.Rules.NIF.NifPanic,
    Archdo.Rules.NIF.NifBehindBehaviour,
    Archdo.Rules.NIF.NifSchedulerSafety,
    Archdo.Rules.NIF.PortVsNif,
    # Event sourcing rules
    Archdo.Rules.EventSourcing.CommandEventNaming,
    Archdo.Rules.EventSourcing.EventPayloadUnversioned,
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
    Archdo.Rules.Testing.MoxStubInTestBody,
    Archdo.Rules.Testing.ChangesetErrorsAccessInTest,
    Archdo.Rules.Testing.EqualsCompareTaggedTupleInTest,
    Archdo.Rules.Testing.StubWithOpportunity,
    Archdo.Rules.Testing.TestTimeoutInfinity,
    Archdo.Rules.Testing.AssertReceiveNoTimeout,
    # Composition rules
    Archdo.Rules.Composition.ShallowUse,
    Archdo.Rules.Composition.NamespaceDepth,
    # Per-file boundary rules
    Archdo.Rules.Boundary.ImportBreadth,
    Archdo.Rules.Boundary.UnusedDependency,
    Archdo.Rules.Boundary.UnvalidatedParams,
    Archdo.Rules.Boundary.AtomAtBoundary,
    Archdo.Rules.Boundary.RawMapInDomain,
    Archdo.Rules.Boundary.InternalStructAsEncoder,
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
    Archdo.Rules.CE.UnguardedBuildingBlock,
    Archdo.Rules.Composition.PipelineOrderFlip,
    Archdo.Rules.Composition.PipelineSideEffectTerminator,
    Archdo.Rules.Composition.OrderedChainConstraints
  ]

  # --- Cross-file (graph) rules ---

  @graph_rules [
    Archdo.Rules.Boundary.DependencyDirection,
    Archdo.Rules.Boundary.FrameworkInDomain,
    Archdo.Rules.Boundary.ContextEncapsulation,
    Archdo.Rules.Boundary.CircularDependencies,
    Archdo.Rules.Boundary.RepoInInterface,
    Archdo.Rules.EventSourcing.SharedProjections
  ]

  # --- Compiled-mode rules (require beam files) ---

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
    Archdo.Rules.Compiled.OrphanModule,
    Archdo.Rules.Compiled.UnanchoredModule
  ]

  # --- Project-level rules (one analyze per project, not per file) ---

  @project_file_ast_rules [
    Archdo.Rules.Boundary.Mockability,
    Archdo.Rules.Module.DuplicatedCode,
    Archdo.Rules.Module.SimilarCode,
    Archdo.Rules.Module.SpeculativeGenerality,
    Archdo.Rules.Boundary.ParallelHierarchies,
    Archdo.Rules.Boundary.SchemaOwnership,
    Archdo.Rules.Module.AdaptersWithoutBehaviour,
    Archdo.Rules.Boundary.SeamIntegrity,
    Archdo.Rules.Module.MissingTelemetry,
    Archdo.Rules.Module.FatInterface,
    Archdo.Rules.Testing.MissingBoundaryTests,
    Archdo.Rules.Boundary.SharedDbTable,
    Archdo.Rules.Boundary.SharedEtsTable,
    Archdo.Rules.Boundary.PrivateModuleCalls,
    Archdo.Rules.Boundary.WidelyUsedInternalModule,
    Archdo.Rules.CE.WrapperOverFramework,
    Archdo.Rules.CE.UnanchoredModule,
    Archdo.Rules.CE.UnanchoredIsland,
    Archdo.Rules.Composition.PipelineShapeMismatch,
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
    Archdo.Rules.CE.DeadRequirement,
    Archdo.Rules.Module.DuplicatedValidation,
    Archdo.Rules.Module.SingleImplProtocol
  ]

  @project_file_path_rules [
    Archdo.Rules.Boundary.GodContext,
    Archdo.Rules.Boundary.AnemicContext
  ]

  # --- Accessors ---

  @doc "List of per-file rule modules."
  @spec phase1_rules() :: [module()]
  def phase1_rules, do: @phase1_rules

  @doc "List of cross-file (graph) rule modules."
  @spec graph_rules() :: [module()]
  def graph_rules, do: @graph_rules

  @doc "List of compiled-mode rule modules (require beam files)."
  @spec compiled_rules() :: [module()]
  def compiled_rules, do: @compiled_rules

  @doc "List of project-level rules taking `[{file, ast}]` tuples."
  @spec project_file_ast_rules() :: [module()]
  def project_file_ast_rules, do: @project_file_ast_rules

  @doc "List of project-level rules taking source file paths."
  @spec project_file_path_rules() :: [module()]
  def project_file_path_rules, do: @project_file_path_rules

  @doc "All project-level rules combined — used by `--list-packs`."
  @spec project_rules() :: [module()]
  def project_rules, do: @project_file_ast_rules ++ @project_file_path_rules

  # --- Module-level metrics ---

  defdelegate main_sequence_distance(metrics, file_map),
    to: MainSequenceDistance,
    as: :analyze_project

  # --- Function-graph rules ---

  defdelegate function_boundary(fn_graph, contexts), to: FunctionBoundary, as: :analyze_project
  defdelegate function_fan_out(fn_graph), to: FunctionFanOut, as: :analyze_project
  defdelegate shotgun_surgery(fn_graph), to: ShotgunSurgery, as: :analyze_project
  defdelegate feature_envy(fn_graph), to: FeatureEnvy, as: :analyze_project
  defdelegate chatty_boundary(fn_graph, contexts), to: ChattyBoundary, as: :analyze_project

  defdelegate sync_context_coupling(fn_graph, contexts),
    to: SyncContextCoupling,
    as: :analyze_project

  # --- Test-project rules ---

  defdelegate test_mirrors_source(source_files, test_files),
    to: TestMirrorsSource,
    as: :analyze_project

  defdelegate coverage_gap(asts), to: CoverageGap, as: :analyze_project
  defdelegate coverage_matrix_report(asts), to: CoverageGap, as: :matrix_report
end
