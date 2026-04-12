defmodule Archdo.Rules.Module.FunctionFanOut do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{Diagnostic, Fix, FunctionGraph}

  @warn_threshold 8
  @error_threshold 15

  @impl true
  def id, do: "6.5"

  @impl true
  def description, do: "Function fan-out — individual functions depending on too many distinct modules"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc """
  Project-level: compute per-function fan-out and flag functions
  that depend on too many distinct external modules.
  """
  def analyze_project(%FunctionGraph{} = graph) do
    fan_out = FunctionGraph.function_fan_out(graph)

    fan_out
    |> Enum.filter(fn {_key, count} -> count > @warn_threshold end)
    # Drop entries with no real function definition (operators, module-level expressions)
    |> Enum.filter(fn {{module, name, arity}, _} ->
      Map.has_key?(graph.definitions, {module, name, arity})
    end)
    |> Enum.map(fn {{module, name, arity}, count} ->
      def_meta = Map.get(graph.definitions, {module, name, arity})
      file = def_meta.file
      line = def_meta.line

      builder = if count > @error_threshold, do: &Diagnostic.warning/2, else: &Diagnostic.info/2

      builder.("6.5",
        title: "Function with high fan-out",
        message:
          "#{module}.#{name}/#{arity} depends on #{count} distinct external modules",
        why:
          "A single function that touches many other modules is doing too much: it has to know how each " <>
            "of them works, it breaks when any of them changes, and it's hard to test because every test has " <>
            "to set up that whole world. High fan-out is the function-level analogue of god classes — the " <>
            "function is becoming a coordinator with too many threads.",
        alternatives: [
          Fix.new(
            summary: "Extract groups of calls into smaller helper functions",
            detail:
              "Identify clusters of calls that go together (e.g. several calls to the same module, or several " <>
                "calls that build one piece of data). Extract each cluster into a private helper. The top-level " <>
                "function shrinks back to orchestration and only one helper depends on each external module.",
            applies_when: "The calls cluster naturally into sub-tasks."
          ),
          Fix.new(
            summary: "Inject dependencies as parameters or split the function",
            detail:
              "If the function is touching many modules because it's a controller for several distinct " <>
                "operations, split it into one function per operation. If the same module is hit repeatedly, " <>
                "wrap that module in a parameter so the function depends on a single 'context' value.",
            applies_when: "The function is doing several distinct operations."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#6.5"],
        context: %{function: "#{module}.#{name}/#{arity}", fan_out: count, threshold: @warn_threshold},
        file: file,
        line: line
      )
    end)
  end
end
