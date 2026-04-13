defmodule Archdo.Runner do
  @moduledoc false

  alias Archdo.{AST, Config, Graph}

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
    Archdo.Rules.Module.ReinventedPubSub,
    Archdo.Rules.Module.ReinventedEnumerable,
    Archdo.Rules.Module.RescueSwallowsError,
    Archdo.Rules.Module.RaiseInNonBang,
    Archdo.Rules.Module.InconsistentErrorShape,
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
    # Composition rules
    Archdo.Rules.Composition.ShallowUse,
    Archdo.Rules.Composition.NamespaceDepth,
    # Per-file boundary rules
    Archdo.Rules.Boundary.ImportBreadth,
    Archdo.Rules.Boundary.UnusedDependency,
    # Resilience rules
    Archdo.Rules.Module.UnprotectedExternalCall,
    Archdo.Rules.Module.UnboundedExternalCall
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
  def phase1_rules, do: @phase1_rules

  @doc """
  Returns the list of cross-file (graph) rule modules.
  """
  def graph_rules, do: @graph_rules

  @doc """
  Analyze files with per-file rules (Phase 1).
  """
  def analyze(files, opts \\ []) do
    enabled_rules = filter_rules(@phase1_rules, opts)

    files
    |> Task.async_stream(
      fn file -> analyze_file(file, enabled_rules, opts) end,
      ordered: false,
      timeout: 30_000
    )
    |> Enum.flat_map(fn
      {:ok, diagnostics} -> diagnostics
      {:exit, _reason} -> []
    end)
    |> sort_diagnostics()
  end

  @doc """
  Analyze files with both per-file rules AND graph-based boundary rules (Phase 2).
  """
  def analyze_with_graph(files, opts \\ []) do
    # Phase 1: per-file analysis
    per_file_diagnostics = analyze(files, opts)

    # Phase 2: build graph and run boundary rules
    config = Keyword.get_lazy(opts, :config, fn -> Config.load() end)
    graph_diagnostics = run_graph_rules(files, config, opts)

    (per_file_diagnostics ++ graph_diagnostics)
    |> sort_diagnostics()
  end

  defp run_graph_rules(files, config, opts) do
    enabled_rules = filter_rules(@graph_rules, opts)

    if enabled_rules == [] do
      []
    else
      # Parse all files and build the graph
      file_asts =
        files
        |> Enum.map(fn file ->
          case AST.parse_file(file) do
            {:ok, ast} -> {file, ast}
            {:error, _} -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      graph = Graph.build(file_asts)

      Enum.flat_map(enabled_rules, fn rule ->
        if function_exported?(rule, :analyze_graph, 2) do
          rule.analyze_graph(graph, config)
        else
          []
        end
      end)
    end
  end

  defp analyze_file(file, rules, opts) do
    case AST.parse_file(file) do
      {:ok, ast} ->
        Enum.flat_map(rules, fn rule ->
          rule.analyze(file, ast, opts)
        end)

      {:error, _reason} ->
        []
    end
  end

  defp filter_rules(rules, opts) do
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

  defp sort_diagnostics(diagnostics) do
    Enum.sort_by(diagnostics, fn d -> {severity_order(d.severity), d.file, d.line} end)
  end

  defp severity_order(:error), do: 0
  defp severity_order(:warning), do: 1
  defp severity_order(:info), do: 2
end
