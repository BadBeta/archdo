defmodule Archdo.Rules.Module.FeatureEnvy do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{Diagnostic, Fix, FunctionGraph}

  # A function is "envious" if it calls another module > N times its own module
  @envy_ratio 3
  # And makes at least this many external calls
  @min_external_calls 4

  # Standard library modules — calling these frequently isn't "envy",
  # you can't move your function into Enum.
  @stdlib MapSet.new(~w(
    Enum List Map MapSet Keyword Process Kernel IO File Path String Integer Float
    Atom Tuple Range Stream Function Module Code Macro Application System
    Logger GenServer Agent Task Supervisor DynamicSupervisor Registry
    Ecto Phoenix Plug Regex Date Time DateTime NaiveDateTime Calendar
    Base64 Bitwise Exception Access URI Version
  ))

  @impl true
  def id, do: "4.9"

  @impl true
  def description, do: "Feature envy — function calls another module more than its own"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc """
  Project-level: for each function, group its outgoing calls by target module.
  Flag functions where another module dominates the call pattern.
  """
  def analyze_project(%FunctionGraph{} = graph) do
    graph.calls
    |> Enum.filter(fn call -> call.caller_fn != nil end)
    |> Enum.group_by(fn call -> {call.caller_module, call.caller_fn, call.caller_arity} end)
    |> Enum.flat_map(&envy_diags_for_caller(&1, graph))
  end

  defp envy_diags_for_caller({{caller_mod, name, arity}, calls}, graph) do
    target_counts = calls |> Enum.map(& &1.target_module) |> Enum.frequencies()
    self_calls = Map.get(target_counts, caller_mod, 0)

    # Find the dominant external module — exclude stdlib (you can't move into Enum)
    external =
      target_counts
      |> Map.delete(caller_mod)
      |> Enum.reject(fn {mod, _} -> stdlib?(mod) end)
      |> Map.new()

    diag_for_dominant(
      Enum.max_by(external, fn {_mod, c} -> c end, fn -> nil end),
      caller_mod,
      name,
      arity,
      self_calls,
      graph
    )
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # the dominant-module shape (nil / below threshold / envious /
  # not envious).
  defp diag_for_dominant({dominant_mod, count}, caller_mod, name, arity, self_calls, graph)
       when count >= @min_external_calls do
    diag_if_envious(envious?(count, self_calls), dominant_mod, count, caller_mod, name, arity, self_calls, graph)
  end

  defp diag_for_dominant(_other, _caller_mod, _name, _arity, _self_calls, _graph) do
    fallback_no_diag()
  end

  defp diag_if_envious(false, _dominant_mod, _count, _caller_mod, _name, _arity, _self_calls, _graph), do: []

  defp diag_if_envious(true, dominant_mod, count, caller_mod, name, arity, self_calls, graph) do
    {file, line} = caller_location(Map.get(graph.definitions, {caller_mod, name, arity}))
    [build_envy_diagnostic(caller_mod, name, arity, dominant_mod, count, self_calls, file, line)]
  end

  defp caller_location(nil), do: {"unknown", 0}
  defp caller_location(meta), do: {meta.file, meta.line}

  defp fallback_no_diag, do: []

  defp build_envy_diagnostic(caller_mod, name, arity, dominant_mod, count, self_calls, file, line) do
    Diagnostic.info("4.9",
      title: "Feature envy",
      message:
        "#{caller_mod}.#{name}/#{arity} calls #{dominant_mod} #{count}x but its own module only #{self_calls}x",
      why:
        "When a function reaches into another module much more than its own, that other module is " <>
          "where the function naturally belongs. Splitting the function from the data it operates on " <>
          "creates feature envy: the caller module knows nothing useful and the dependency direction " <>
          "is wrong. Refactoring it back into #{dominant_mod} reduces coupling and clarifies ownership.",
      alternatives: [
        Fix.new(
          summary: "Move the function into #{dominant_mod}",
          detail:
            "Cut the function from #{caller_mod} and paste it into #{dominant_mod}. Update " <>
              "callers to point at the new location. The function ends up next to the data it " <>
              "manipulates and the inter-module dependency disappears.",
          applies_when: "#{dominant_mod} is the natural home for this logic."
        ),
        Fix.new(
          summary:
            "Add a higher-level operation to #{dominant_mod} and have #{caller_mod} call it",
          detail:
            "If the function does something specific to #{caller_mod} but also pokes deep into " <>
              "#{dominant_mod}'s internals, add a new public operation on #{dominant_mod} that hides " <>
              "the internal accesses. #{caller_mod} keeps its function but only makes one outbound call.",
          applies_when:
            "The function belongs in caller_mod conceptually but needs cleaner access to dominant_mod."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#4.9"],
      context: %{
        function: "#{caller_mod}.#{name}/#{arity}",
        envious_target: dominant_mod,
        external_calls: count,
        self_calls: self_calls
      },
      file: file,
      line: line
    )
  end

  # Require the function to make at least some self-references (otherwise
  # it's just a thin wrapper, not envy). Then require the external module
  # to dominate by the envy ratio.
  defp envious?(external_count, self_count) do
    self_count >= 1 and external_count >= self_count * @envy_ratio
  end

  defp stdlib?(mod) when is_binary(mod) do
    # Strip any sub-namespace — we want top-level matches
    top =
      mod
      |> String.split(".")
      |> hd()

    MapSet.member?(@stdlib, top)
  end

  defp stdlib?(_), do: false
end
