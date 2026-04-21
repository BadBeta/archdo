defmodule Archdo.Rules.Boundary.ShotgunSurgery do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{Diagnostic, Fix, FunctionGraph}

  @max_caller_modules 10

  @impl true
  def id, do: "1.8"

  @impl true
  def description, do: "Functions with too many distinct callers — change ripple risk"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc """
  Project-level: for each function definition, count distinct caller modules.
  High fan-in means a change to this function will require updates across many modules.
  """
  def analyze_project(%FunctionGraph{} = graph) do
    Enum.flat_map(graph.definitions, fn {{module, name, arity}, def_meta} ->
      callers =
        FunctionGraph.calls_to(graph, module, name, arity)
        |> Enum.map(fn call -> call.caller_module end)
        |> Enum.uniq()
        |> Enum.reject(fn caller -> caller == module end)

      caller_count = length(callers)

      if caller_count > @max_caller_modules do
        [
          Diagnostic.info("1.8",
            title: "High fan-in function (shotgun-surgery risk)",
            message:
              "#{module}.#{name}/#{arity} is called from #{caller_count} distinct modules",
            why:
              "Functions with very high fan-in are change-ripple amplifiers: any signature change touches every " <>
                "caller, so the function becomes implicitly frozen and the codebase routes around it instead of " <>
                "evolving. High fan-in is also a hint the abstraction is doing too much — multiple distinct " <>
                "consumers want different shapes and the function is trying to serve all of them.",
            alternatives: [
              Fix.new(
                summary: "Treat the function as part of a stable API and document it",
                detail:
                  "If the high fan-in is intentional (it's a core utility), promote it to a documented public " <>
                    "API with `@spec`, examples, and a moduledoc note that changes are breaking. Add it to the " <>
                    "freeze baseline so future changes are deliberate.",
                applies_when: "The function is genuinely a stable building block."
              ),
              Fix.new(
                summary: "Split the function into smaller, more specific variants",
                detail:
                  "Different callers usually want different shapes of the same data. Replace the one big " <>
                    "function with several focused ones (e.g. `list_users/0`, `list_active_users/0`, " <>
                    "`list_users_with_role/1`). Each call site picks the variant it actually needs.",
                applies_when: "Callers want different subsets of behaviour."
              ),
              Fix.new(
                summary: "Reduce fan-in by introducing an intermediate layer",
                detail:
                  "If most callers route through a small handful of helper modules, push the call there and " <>
                    "have the rest of the codebase use those helpers. Fan-in concentrates instead of spreading.",
                applies_when: "There's a natural intermediate that can absorb the call."
              )
            ],
            references: ["ARCHITECTURE_RULES.md#1.8"],
            context: %{
              function: "#{module}.#{name}/#{arity}",
              caller_count: caller_count,
              threshold: @max_caller_modules
            },
            file: def_meta.file,
            line: def_meta.line
          )
        ]
      else
        []
      end
    end)
  end
end
