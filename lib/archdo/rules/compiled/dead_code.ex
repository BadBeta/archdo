defmodule Archdo.Rules.Compiled.DeadCode do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.Compiled
  alias Archdo.{Diagnostic, Fix}

  @impl true
  def id, do: "6.24"

  @impl true
  def description, do: "Public function exported but never called — dead code"

  # Per-file analysis returns nothing — this rule requires compiled beam data
  @doc """
  Compiled-mode analysis using the interaction graph.
  """
  @spec analyze_compiled(Compiled.t()) :: [Diagnostic.t()]
  def analyze_compiled(graph), do: analyze_compiled(graph, [])

  @spec analyze_compiled(Compiled.t(), keyword()) :: [Diagnostic.t()]
  def analyze_compiled(graph, opts) do
    filters = build_filters(graph, opts)

    graph
    |> Compiled.dead_functions()
    |> Enum.reject(&suppress?(&1, filters))
    |> Enum.map(&build_diagnostic/1)
  end

  defp build_filters(graph, opts) do
    %{
      library_publics: Keyword.get(opts, :library_public_modules, MapSet.new()),
      impl_annotated: Keyword.get(opts, :impl_annotated_functions, %{}),
      source_defs: Keyword.get(opts, :source_defined_functions, %{}),
      behaviour_implementors: behaviour_implementor_set(graph),
      project_callback_fns: build_callback_fn_set(graph),
      app_entry_fns: MapSet.new([{:start, 2}, {:stop, 1}])
    }
  end

  defp suppress?(finding, filters) do
    function_in_public_library_module?(finding, filters.library_publics) or
      behaviour_callback_impl?(finding, filters.project_callback_fns) or
      impl_annotated_function?(finding, filters.impl_annotated) or
      macro_injected_callback_default?(
        finding,
        filters.source_defs,
        filters.behaviour_implementors
      ) or
      application_entry_function?(finding, filters.app_entry_fns)
  end

  @doc """
  Checks whether a dead-function finding should be suppressed because it's a
  macro-injected callback default.

  A finding qualifies for suppression when ALL of:
  1. The module declares one or more `@behaviour Mod` (so it's reached via
     callback dispatch from the framework that owns the behaviour).
  2. The function `{name, arity}` is NOT in the module's source-defined
     function set — meaning the function exists in the compiled BEAM but
     not in any `def` / `defp` in the source AST.

  This catches the common case of `use SomeBehaviour` macros that inject
  default callback implementations: the BEAM has them as exports but no
  source-level `def` annotates them with `@impl`.

  Public for direct testing.
  """
  @spec macro_injected_callback_default?(
          %{module: module(), function: atom(), arity: arity()},
          %{module() => MapSet.t({atom(), arity()})},
          MapSet.t(module())
        ) :: boolean()
  def macro_injected_callback_default?(
        %{module: module, function: fun, arity: arity},
        source_defs,
        behaviour_implementor_modules
      ) do
    in_behaviour_module? = MapSet.member?(behaviour_implementor_modules, module)

    in_source? =
      case Map.get(source_defs, module) do
        nil -> false
        defs -> MapSet.member?(defs, {fun, arity})
      end

    in_behaviour_module? and not in_source?
  end

  # Build the set of modules that declare any `@behaviour Mod` based on the
  # compiled graph's `:behaviours` field per module.
  defp behaviour_implementor_set(graph) do
    for {mod, %{behaviours: [_ | _]}} <- Compiled.modules(graph),
        into: MapSet.new(),
        do: mod
  end

  # Library mode: a "dead" public function in a public-API module is almost
  # certainly called by consumers Archdo can't see. Skip those findings.
  # The rule still fires on functions in `@moduledoc false` modules — those
  # are intentionally non-public and being unused inside the library is real.
  defp function_in_public_library_module?(%{module: module}, library_publics) do
    MapSet.member?(library_publics, module)
  end

  # A function that implements a callback of one of its module's behaviours
  # is reached via `apply(mod, callback_name, args)` from the framework that
  # owns the behaviour — invisible to static analysis. Skip those findings.
  defp behaviour_callback_impl?(%{module: module, function: fun, arity: arity}, callback_fns) do
    case Map.get(callback_fns, module) do
      nil -> false
      cbs -> MapSet.member?(cbs, {fun, arity})
    end
  end

  # `@impl true` (or `@impl Mod`) in source AST is the strongest signal
  # that a function implements a behaviour callback. Catches the common
  # case where the behaviour module lives outside the analyzed paths
  # (e.g. ThousandIsland.Handler, Plug.Conn.Adapter, GenServer) and so
  # is invisible to the project_callback_fns lookup.
  defp impl_annotated_function?(
         %{module: module, function: fun, arity: arity},
         impl_annotated
       ) do
    case Map.get(impl_annotated, module) do
      nil -> false
      callbacks -> MapSet.member?(callbacks, {fun, arity})
    end
  end

  # `start/2` and `stop/1` in any module are reached by the BEAM application
  # loader, not by Elixir code. The 1.26 rule already excludes
  # `*.Application` modules; this is the function-level analogue for 6.24.
  defp application_entry_function?(%{module: module, function: fun, arity: arity}, app_entry_fns) do
    name = Atom.to_string(module)

    String.ends_with?(name, ".Application") and MapSet.member?(app_entry_fns, {fun, arity})
  end

  # For every module that declares `@behaviour Mod`, look up Mod's callback
  # function set in the compiled graph. Build a `module => MapSet({fn, arity})`
  # map so dead-code findings can be filtered against it.
  #
  # External behaviours (Plug, GenServer, OTP Application) may not appear in
  # the graph at all — those modules contribute nothing to this map. The
  # `behaviour_implementor?` exclusion in rule 1.26 covers the module-level
  # case for those (any module declaring `@behaviour Mod` is anchored
  # regardless of whether Mod is in the graph).
  defp build_callback_fn_set(graph) do
    modules = Compiled.modules(graph)

    for {mod, %{behaviours: [_ | _] = behaviours}} <- modules,
        callbacks = collect_callbacks(behaviours, modules),
        MapSet.size(callbacks) > 0,
        into: %{},
        do: {mod, callbacks}
  end

  defp collect_callbacks(behaviours, modules) do
    behaviours
    |> Enum.flat_map(&behaviour_callbacks(&1, modules))
    |> Enum.map(&callback_to_arity/1)
    |> MapSet.new()
  end

  defp behaviour_callbacks(behaviour, modules) do
    case Map.get(modules, behaviour) do
      %{callback_fns: cbs} when is_list(cbs) -> cbs
      _ -> []
    end
  end

  defp callback_to_arity({_name, _arity} = pair), do: pair
  defp callback_to_arity(%{name: name, arity: arity}), do: {name, arity}

  defp callback_to_arity({name, arity, _kind}) when is_atom(name) and is_integer(arity),
    do: {name, arity}

  defp build_diagnostic(%{module: module, function: func, arity: arity}) do
    mod_name =
      module
      |> Atom.to_string()
      |> String.replace_leading("Elixir.", "")

    Diagnostic.info("6.24",
      title: "Dead public function",
      message:
        "#{mod_name}.#{func}/#{arity} is exported but never called from outside the module",
      why:
        "Public functions are part of the module's API contract. An exported function that " <>
          "nobody calls is dead weight — it increases the API surface callers must understand, " <>
          "survives refactors that should have removed it, and may mislead developers into " <>
          "thinking it's part of the supported interface. If it's truly unused, make it " <>
          "`defp` or delete it. If it's called dynamically (via apply/3 or protocol dispatch), " <>
          "the xref analysis may have missed it — verify before removing.",
      alternatives: [
        Fix.new(
          summary: "Make it private (defp) if only used internally",
          detail:
            "Change `def #{func}` to `defp #{func}`. The compiler will error if " <>
              "any external module tries to call it, confirming it's safe.",
          applies_when: "The function is used within the module but not outside."
        ),
        Fix.new(
          summary: "Delete if completely unused",
          detail:
            "Remove the function entirely. Run `mix compile` to verify nothing breaks. " <>
              "If it was called dynamically (apply/3, protocol dispatch), the compiler " <>
              "won't catch it — check at runtime too.",
          applies_when: "The function is not used anywhere."
        ),
        Fix.new(
          summary: "Keep and document if it's part of a public API",
          detail:
            "If the function is intentionally public for external consumers (library API, " <>
              "callback, or plugin hook), add @doc to document it and add a test that " <>
              "exercises it.",
          applies_when: "The function is called by consumers outside this project."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.24"],
      context: %{
        module: mod_name,
        function: "#{func}/#{arity}"
      },
      file: "lib",
      line: 0
    )
  end
end
