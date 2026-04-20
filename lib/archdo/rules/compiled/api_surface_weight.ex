defmodule Archdo.Rules.Compiled.ApiSurfaceWeight do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Compiled.Graph
  alias Archdo.Rules.Compiled.Helpers

  @impl true
  def id, do: "6.26"

  @impl true
  def description, do: "Module exports many functions but few are used externally"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  # Flag when less than this fraction of exports are used externally
  @usage_threshold 0.25
  # Minimum exports to consider — don't flag small modules
  @min_exports 8

  @spec analyze_compiled(Graph.t()) :: [Diagnostic.t()]
  def analyze_compiled(%Graph{modules: modules} = graph) do
    modules
    |> Enum.flat_map(fn {module, info} ->
      total_exports = length(info.exports)

      case total_exports >= @min_exports do
        true ->
          usage = Graph.external_usage(graph, module)

          externally_used =
            Enum.count(usage, fn {_fa, count} -> count > 0 end)

          ratio = externally_used / total_exports

          case ratio < @usage_threshold do
            true ->
              [build_diagnostic(module, externally_used, total_exports, usage)]

            false ->
              []
          end

        false ->
          []
      end
    end)
  end

  defp build_diagnostic(module, externally_used, total_exports, usage) do
    mod_name = AST.module_name(module)

    unused_fns =
      usage
      |> Enum.filter(fn {_fa, count} -> count == 0 end)
      |> Enum.map(fn {{f, a}, _} -> "#{f}/#{a}" end)
      |> Enum.sort()
      |> Enum.take(10)
      |> Enum.join(", ")

    Diagnostic.info("6.26",
      title: "Oversized API surface",
      message:
        "#{mod_name} exports #{total_exports} functions but only #{externally_used} " <>
          "(#{Helpers.percentage(externally_used, total_exports)}%) are called externally",
      why:
        "A module with many exports but few external callers has an oversized public API. " <>
          "Every exported function is a contract — callers must understand it, documentation " <>
          "must cover it, and changes to it risk breaking consumers. Functions that are only " <>
          "used internally should be private (defp).",
      alternatives: [
        Fix.new(
          summary: "Make unused exports private",
          detail:
            "Consider making these functions private: #{unused_fns}",
          applies_when: "The functions are only used within the module."
        ),
        Fix.new(
          summary: "Split into public API and internal module",
          detail:
            "Move internal helpers to a child module (e.g., #{mod_name}.Internal) " <>
              "and keep only the truly public API in #{mod_name}.",
          applies_when: "The module mixes public API with implementation helpers."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.26"],
      context: %{
        module: mod_name,
        externally_used: externally_used,
        total_exports: total_exports
      },
      file: "lib",
      line: 0
    )
  end

end
