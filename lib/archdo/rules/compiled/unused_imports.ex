defmodule Archdo.Rules.Compiled.UnusedImports do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Compiled.Graph
  alias Archdo.Rules.Compiled.Helpers

  @impl true
  def id, do: "4.22"

  @impl true
  def description, do: "Import brings many functions but few are used"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  # Threshold: if less than this fraction of imported functions are used, flag it
  @usage_threshold 0.5
  # Minimum exports to consider — don't flag imports of small modules
  @min_exports 5

  @spec analyze_compiled(Graph.t()) :: [Diagnostic.t()]
  def analyze_compiled(%Graph{modules: modules, calls_by_module: calls_by_module} = _graph) do
    # For each module, look at what it calls from each other module.
    # If module A calls only 2 of module B's 20 exports, the dependency is
    # import-like and could benefit from `import Module, only: [...]`.
    #
    # We detect this at the module-to-module level since we can't distinguish
    # import from alias in compiled beam data.

    Enum.flat_map(modules, fn {caller_mod, _info} ->
      caller_calls = Map.get(calls_by_module, caller_mod, [])

      # Group calls by callee module
      calls_by_target =
        Enum.group_by(caller_calls, fn call -> elem(call.callee, 0) end)

      calls_by_target
      |> Enum.filter(fn {target_mod, _calls} ->
        # Only check project modules (those in our modules map)
        Map.has_key?(modules, target_mod) and target_mod != caller_mod
      end)
      |> Enum.flat_map(fn {target_mod, calls} ->
        target_exports = Map.get(modules, target_mod, %{exports: []}).exports
        total_exports = length(target_exports)

        case total_exports >= @min_exports do
          true ->
            used_fns =
              calls
              |> Enum.map(fn call -> {elem(call.callee, 1), elem(call.callee, 2)} end)
              |> Enum.uniq()

            used_count = length(used_fns)
            usage_ratio = used_count / total_exports

            case usage_ratio < @usage_threshold do
              true ->
                [build_diagnostic(caller_mod, target_mod, used_count, total_exports, used_fns)]

              false ->
                []
            end

          false ->
            []
        end
      end)
    end)
  end

  defp build_diagnostic(caller_mod, target_mod, used_count, total_exports, used_fns) do
    caller_name = AST.module_name(caller_mod)
    target_name = AST.module_name(target_mod)

    only_list =
      used_fns
      |> Enum.sort()
      |> Enum.map_join(", ", fn {f, a} -> "#{f}/#{a}" end)

    Diagnostic.info("4.22",
      title: "Low import utilization",
      message:
        "#{caller_name} uses #{used_count} of #{total_exports} exports " <>
          "from #{target_name} (#{Helpers.percentage(used_count, total_exports)}%)",
      why:
        "When a module depends on another but uses only a small fraction of its API, " <>
          "the dependency is wider than necessary. This makes the caller harder to " <>
          "understand (which functions does it actually need?) and creates unnecessary " <>
          "coupling. Consider using `import #{target_name}, only: [...]` to make the " <>
          "actual dependency explicit.",
      alternatives: [
        Fix.new(
          summary: "Use targeted import",
          detail: "import #{target_name}, only: [#{only_list}]",
          applies_when: "The module uses import without :only."
        ),
        Fix.new(
          summary: "Use fully qualified calls instead",
          detail: "Replace unqualified calls with #{target_name}.function() calls.",
          applies_when: "The import can be removed entirely."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#4.22"],
      context: %{
        caller: caller_name,
        target: target_name,
        used: used_count,
        total: total_exports
      },
      file: "lib",
      line: 0
    )
  end
end
