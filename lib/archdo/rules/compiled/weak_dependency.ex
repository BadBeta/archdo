defmodule Archdo.Rules.Compiled.WeakDependency do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Compiled

  @impl true
  def id, do: "4.23"

  @impl true
  def description, do: "Module depends on another but uses very few of its exports"

  # Flag when using <= this many functions from a module with >= @min_target_exports
  @max_used_functions 2
  @min_target_exports 10

  @spec analyze_compiled(Compiled.t()) :: [Diagnostic.t()]
  def analyze_compiled(graph) do
    modules = Compiled.modules(graph)
    calls_by_module = Compiled.calls_by_module(graph)

    Enum.flat_map(modules, &caller_diagnostics(&1, modules, calls_by_module))
  end

  defp caller_diagnostics({caller_mod, _info}, modules, calls_by_module) do
    calls_by_module
    |> Map.get(caller_mod, [])
    |> Enum.group_by(fn call -> elem(call.callee, 0) end)
    |> Enum.filter(fn {target_mod, _} ->
      Map.has_key?(modules, target_mod) and target_mod != caller_mod
    end)
    |> Enum.flat_map(&target_diagnostic(&1, caller_mod, modules))
  end

  defp target_diagnostic({target_mod, calls}, caller_mod, modules) do
    target_exports = Map.get(modules, target_mod, %{exports: []}).exports
    total_exports = length(target_exports)

    used_fns =
      calls |> Enum.map(fn c -> {elem(c.callee, 1), elem(c.callee, 2)} end) |> Enum.uniq()

    weak_enough? =
      total_exports >= @min_target_exports and length(used_fns) <= @max_used_functions

    # §§ elixir-implementing: §2.1 — boolean → multi-clause head
    diagnostic_if_weak(weak_enough?, caller_mod, target_mod, used_fns, total_exports)
  end

  defp diagnostic_if_weak(false, _caller, _target, _used, _total), do: []

  defp diagnostic_if_weak(true, caller_mod, target_mod, used_fns, total_exports),
    do: [build_diagnostic(caller_mod, target_mod, used_fns, total_exports)]

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
