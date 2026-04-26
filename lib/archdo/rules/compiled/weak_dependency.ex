defmodule Archdo.Rules.Compiled.WeakDependency do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Compiled.Graph

  @impl true
  def id, do: "4.23"

  @impl true
  def description, do: "Module depends on another but uses very few of its exports"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  # Flag when using <= this many functions from a module with >= @min_target_exports
  @max_used_functions 2
  @min_target_exports 10

  @spec analyze_compiled(Graph.t()) :: [Diagnostic.t()]
  def analyze_compiled(%Graph{modules: modules, calls_by_module: calls_by_module}) do
    Enum.flat_map(modules, fn {caller_mod, _info} ->
      caller_calls = Map.get(calls_by_module, caller_mod, [])

      calls_by_target =
        Enum.group_by(caller_calls, fn call -> elem(call.callee, 0) end)

      calls_by_target
      |> Enum.filter(fn {target_mod, _calls} ->
        Map.has_key?(modules, target_mod) and target_mod != caller_mod
      end)
      |> Enum.flat_map(fn {target_mod, calls} ->
        target_exports = Map.get(modules, target_mod, %{exports: []}).exports
        total_exports = length(target_exports)

        used_fns =
          calls
          |> Enum.map(fn call -> {elem(call.callee, 1), elem(call.callee, 2)} end)
          |> Enum.uniq()

        used_count = length(used_fns)

        case total_exports >= @min_target_exports and used_count <= @max_used_functions do
          true ->
            [build_diagnostic(caller_mod, target_mod, used_fns, total_exports)]

          false ->
            []
        end
      end)
    end)
  end

  defp build_diagnostic(caller_mod, target_mod, used_fns, total_exports) do
    caller_name = AST.module_name(caller_mod)
    target_name = AST.module_name(target_mod)

    used_str =
      used_fns
      |> Enum.sort()
      |> Enum.map_join(", ", fn {f, a} -> "#{f}/#{a}" end)

    Diagnostic.info("4.23",
      title: "Weak dependency",
      message:
        "#{caller_name} uses only #{length(used_fns)} of #{total_exports} exports " <>
          "from #{target_name}: #{used_str}",
      why:
        "A module that depends on another but uses only 1-2 of its many exports " <>
          "has a weak dependency. This can indicate that the caller should depend on " <>
          "a more focused interface, or that the target module has too broad an API. " <>
          "The dependency creates coupling without proportional benefit.",
      alternatives: [
        Fix.new(
          summary: "Extract a focused interface",
          detail:
            "If #{target_name} is a large module, consider extracting the functions " <>
              "#{caller_name} needs into a smaller, focused module.",
          applies_when: "Multiple callers each use a different small subset."
        ),
        Fix.new(
          summary: "Accept the dependency",
          detail:
            "If #{target_name} is a cohesive module and the #{length(used_fns)} " <>
              "functions used are part of its core purpose, the dependency is fine.",
          applies_when: "The target module is well-designed and the usage is intentional."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#4.23"],
      context: %{
        caller: caller_name,
        target: target_name,
        used_functions: used_str,
        target_export_count: total_exports
      },
      file: "lib",
      line: 0
    )
  end
end
