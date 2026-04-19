defmodule Archdo.Rules.Compiled.InternalModuleLeak do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{Diagnostic, Fix}
  alias Archdo.Compiled.Graph

  @impl true
  def id, do: "4.25"

  @impl true
  def description, do: "Internal module (child of a context) called from outside its context"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  # A module used by more than this many external modules is infrastructure, not internal
  @widely_used_threshold 5

  @spec analyze_compiled(Graph.t()) :: [Diagnostic.t()]
  def analyze_compiled(%Graph{modules: modules, calls: calls} = graph) do
    project_modules = MapSet.new(Map.keys(modules))

    # Identify internal modules: modules that are children of a parent module
    # (e.g., Archdo.Runner.Helpers is internal to Archdo.Runner)
    # We consider a module "internal" if its parent module also exists in the project
    # and the child is not itself a context-level module.
    #
    # Exclude modules that are widely used — they're shared infrastructure, not internal.
    internal_modules =
      modules
      |> Map.keys()
      |> Enum.filter(fn mod ->
        parent = parent_module(mod)
        parent != nil and MapSet.member?(project_modules, parent) and
          not widely_used?(graph, mod)
      end)
      |> MapSet.new()

    # Find calls from outside a module's parent context into internal modules
    calls
    |> Enum.filter(fn call ->
      callee_mod = elem(call.callee, 0)
      caller_mod = elem(call.caller, 0)

      MapSet.member?(internal_modules, callee_mod) and
        MapSet.member?(project_modules, caller_mod) and
        not same_context?(caller_mod, callee_mod)
    end)
    |> Enum.group_by(fn call ->
      {elem(call.caller, 0), elem(call.callee, 0)}
    end)
    |> Enum.map(fn {{caller_mod, callee_mod}, mod_calls} ->
      build_diagnostic(caller_mod, callee_mod, mod_calls)
    end)
  end

  defp widely_used?(graph, mod) do
    dependents = Graph.module_dependents(graph, mod)
    length(dependents) > @widely_used_threshold
  end

  # Get the parent module (one level up)
  defp parent_module(mod) do
    parts = Module.split(mod)

    case length(parts) do
      n when n > 1 ->
        parts
        |> Enum.take(n - 1)
        |> Module.concat()

      _ ->
        nil
    end
  end

  # Two modules are in the same context if they share the same top-level
  # parent (two levels deep). E.g., Archdo.Rules.OTP.X and Archdo.Rules.OTP.Y
  # share Archdo.Rules.OTP.
  # More precisely: same if one is a prefix of the other or they share
  # a common ancestor at the context level.
  defp same_context?(mod_a, mod_b) do
    a_str = format_mod(mod_a)
    b_str = format_mod(mod_b)

    # Find common prefix — they're in the same context if one is a parent of the other
    # or they share the same parent
    String.starts_with?(a_str, b_str <> ".") or
      String.starts_with?(b_str, a_str <> ".") or
      same_parent?(mod_a, mod_b)
  end

  defp same_parent?(mod_a, mod_b) do
    parent_module(mod_a) == parent_module(mod_b)
  end

  defp build_diagnostic(caller_mod, callee_mod, calls) do
    caller_name = format_mod(caller_mod)
    callee_name = format_mod(callee_mod)
    parent_name = format_mod(parent_module(callee_mod))

    functions_called =
      calls
      |> Enum.map(fn call ->
        {f, a} = {elem(call.callee, 1), elem(call.callee, 2)}
        "#{f}/#{a}"
      end)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.join(", ")

    Diagnostic.info("4.25",
      title: "Internal module accessed from outside",
      message:
        "#{caller_name} calls #{callee_name} (internal to #{parent_name}): #{functions_called}",
      why:
        "#{callee_name} is a child module of #{parent_name}, which typically means " <>
          "it's an internal implementation detail. #{caller_name} calls it directly, " <>
          "creating a dependency on internals that may change without notice. " <>
          "This is detected from compiled beam data — it accounts for macro-injected calls.",
      alternatives: [
        Fix.new(
          summary: "Expose needed functionality through #{parent_name}",
          detail:
            "Add a public function to #{parent_name} that delegates to " <>
              "#{callee_name}. External callers use the parent's API.",
          applies_when: "The functionality should be part of the parent's public API."
        ),
        Fix.new(
          summary: "Accept the coupling if it's a shared utility",
          detail:
            "If #{callee_name} is a shared utility (like a type module or helper), " <>
              "consider making it a sibling module rather than a child.",
          applies_when: "The module is intentionally shared across boundaries."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#4.25"],
      context: %{
        caller: caller_name,
        internal_module: callee_name,
        parent: parent_name,
        functions: functions_called,
        call_count: length(calls)
      },
      file: "lib",
      line: 0
    )
  end

  defp format_mod(mod) do
    mod
    |> Atom.to_string()
    |> String.replace_leading("Elixir.", "")
  end
end
