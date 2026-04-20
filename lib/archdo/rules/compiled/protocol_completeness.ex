defmodule Archdo.Rules.Compiled.ProtocolCompleteness do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Compiled.Graph

  @impl true
  def id, do: "4.24"

  @impl true
  def description, do: "Protocol implementation missing required functions"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @spec analyze_compiled(Graph.t()) :: [Diagnostic.t()]
  def analyze_compiled(%Graph{modules: modules} = graph) do
    # Check behaviour implementations: for each module that declares @behaviour,
    # verify it exports all required callbacks
    modules
    |> Enum.flat_map(fn {module, info} ->
      info.behaviours
      |> Enum.flat_map(fn behaviour ->
        required_callbacks = Graph.callbacks_for(graph, behaviour)

        case required_callbacks do
          [] ->
            []

          _ ->
            module_exports = MapSet.new(info.exports)

            missing =
              Enum.reject(required_callbacks, fn {func, arity} ->
                MapSet.member?(module_exports, {func, arity})
              end)

            case missing do
              [] -> []
              _ -> [build_diagnostic(module, behaviour, missing)]
            end
        end
      end)
    end)
  end

  defp build_diagnostic(module, behaviour, missing) do
    mod_name = AST.module_name(module)
    bhv_name = AST.module_name(behaviour)

    missing_str =
      missing
      |> Enum.sort()
      |> Enum.map_join(", ", fn {f, a} -> "#{f}/#{a}" end)

    Diagnostic.warning("4.24",
      title: "Incomplete behaviour implementation",
      message:
        "#{mod_name} implements #{bhv_name} but is missing: #{missing_str}",
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
