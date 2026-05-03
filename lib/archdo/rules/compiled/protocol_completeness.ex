defmodule Archdo.Rules.Compiled.ProtocolCompleteness do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Compiled

  @impl true
  def id, do: "4.24"

  @impl true
  def description, do: "Protocol implementation missing required functions"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @spec analyze_compiled(Compiled.t()) :: [Diagnostic.t()]
  def analyze_compiled(graph) do
    modules = Compiled.modules(graph)

    # Check behaviour implementations: for each module that declares @behaviour,
    # verify it exports all required callbacks
    Enum.flat_map(modules, fn {module, info} ->
      Enum.flat_map(info.behaviours, &missing_callbacks_diag(&1, module, info, graph))
    end)
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatches on
  # the empty-list shape of required_callbacks (no behaviour info →
  # nothing to check) and on the missing list shape (none missing →
  # no diagnostic). Each clause is depth 1.
  defp missing_callbacks_diag(behaviour, module, info, graph) do
    behaviour
    |> then(&Compiled.callbacks_for(graph, &1))
    |> diagnose_missing(behaviour, module, info)
  end

  defp diagnose_missing([], _behaviour, _module, _info), do: []

  defp diagnose_missing(required_callbacks, behaviour, module, info) do
    module_exports = MapSet.new(info.exports)

    required_callbacks
    |> Enum.reject(fn {func, arity} -> MapSet.member?(module_exports, {func, arity}) end)
    |> emit_diag_if_missing(module, behaviour)
  end

  defp emit_diag_if_missing([], _module, _behaviour), do: []
  defp emit_diag_if_missing(missing, module, behaviour), do: [build_diagnostic(module, behaviour, missing)]

  defp build_diagnostic(module, behaviour, missing) do
    mod_name = AST.module_name(module)
    bhv_name = AST.module_name(behaviour)

    missing_str =
      missing
      |> Enum.sort()
      |> Enum.map_join(", ", fn {f, a} -> "#{f}/#{a}" end)

    Diagnostic.warning("4.24",
      title: "Incomplete behaviour implementation",
      message: "#{mod_name} implements #{bhv_name} but is missing: #{missing_str}",
      why:
        "Compiled beam analysis shows this module declares @behaviour #{bhv_name} " <>
          "but doesn't export all required callbacks. This is detected after macro " <>
          "expansion, so macro-injected functions are accounted for. Missing callbacks " <>
          "will cause runtime failures when the behaviour tries to invoke them.",
      alternatives: [
        Fix.new(
          summary: "Implement the missing callbacks",
          detail: "Add `@impl true` definitions for: #{missing_str}",
          applies_when: "The callbacks should be implemented."
        ),
        Fix.new(
          summary: "Remove the @behaviour declaration",
          detail:
            "If this module should not implement #{bhv_name}, " <>
              "remove the `@behaviour #{bhv_name}` declaration.",
          applies_when: "The @behaviour was added by mistake."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#4.24"],
      context: %{
        module: mod_name,
        behaviour: bhv_name,
        missing: missing_str
      },
      file: "lib",
      line: 0
    )
  end
end
