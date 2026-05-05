defmodule Archdo.Rules.Boundary.ContextDrift do
  @moduledoc """
  Detects modules that, by call-graph community membership, belong with
  a different context than the one they're declared under. Compares the
  community returned by `Archdo.Compiled.Graph.Communities` against the
  declared context membership returned by
  `Archdo.Compiled.discover_contexts/1`.

  Module-level rule. Fires only on modules with at least
  `@min_outgoing` outgoing call edges — small modules carry too little
  community signal for this comparison to be reliable.
  """

  Module.register_attribute(__MODULE__, :archdo_volatility, persist: true)
  @archdo_volatility :stable

  alias Archdo.{Compiled, Diagnostic, Fix}
  alias Archdo.Compiled.Graph.Communities

  @id "1.34"
  @min_outgoing 5

  @doc "Rule id."
  def id, do: @id

  @doc "Rule description."
  def description, do: "Module's call-graph community differs from its declared context"

  @doc """
  Compiled-graph entry point. Builds the community labels and the
  per-module outgoing-edge count from `graph`, then delegates to
  `compute_drift/3`.
  """
  @spec analyze_compiled(Compiled.t()) :: [Diagnostic.t()]
  def analyze_compiled(graph) do
    contexts = Compiled.discover_contexts(graph)

    case contexts do
      [] ->
        []

      _ ->
        labels = Communities.label_propagation(graph)
        module_communities = aggregate_by_module(labels)
        outgoing = outgoing_per_module(graph)

        compute_drift(contexts, module_communities, outgoing)
    end
  end

  @doc """
  Pure entry-point for tests and reuse. Takes:

    * `contexts` — list of `%{context: name, members: [module]}`
    * `module_communities` — `%{module => community-id}`
    * `outgoing` — `%{module => non_neg_integer}` outgoing-edge count

  Returns a list of diagnostics for modules whose community differs
  from their context's modal community AND whose outgoing-edge count
  is at least `@min_outgoing`.
  """
  @spec compute_drift(
          [%{context: String.t(), members: [module()]}],
          %{module() => any()},
          %{module() => non_neg_integer()}
        ) :: [Diagnostic.t()]
  def compute_drift(contexts, module_communities, outgoing) do
    Enum.flat_map(contexts, fn ctx ->
      modal = modal_community(ctx.members, module_communities)
      Enum.flat_map(ctx.members, &maybe_drift(&1, ctx, modal, module_communities, outgoing))
    end)
  end

  defp maybe_drift(module, ctx, modal, module_communities, outgoing) do
    out = Map.get(outgoing, module, 0)
    label = Map.get(module_communities, module)

    cond do
      out < @min_outgoing -> []
      label == modal -> []
      label == nil -> []
      true -> [build_diagnostic(ctx.context, module, label, modal)]
    end
  end

  defp modal_community(members, labels) do
    members
    |> Enum.map(&Map.get(labels, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> max_label()
  end

  defp max_label(freqs) when map_size(freqs) == 0, do: nil

  defp max_label(freqs) do
    freqs |> Enum.max_by(fn {_, c} -> c end) |> elem(0)
  end

  # Aggregate per-MFA labels into per-module labels by majority vote
  # over the module's own MFAs.
  defp aggregate_by_module(labels_by_mfa) do
    labels_by_mfa
    |> Enum.group_by(fn {{mod, _f, _a}, _label} -> mod end, fn {_mfa, label} -> label end)
    |> Map.new(fn {mod, labels} ->
      {mod, labels |> Enum.frequencies() |> max_label()}
    end)
  end

  # Outgoing edges per module — count of distinct callees from any
  # function in that module.
  defp outgoing_per_module(graph) do
    graph
    |> Compiled.calls_by_caller()
    |> Enum.group_by(fn {{mod, _, _}, _} -> mod end, fn {_, calls} -> length(calls) end)
    |> Map.new(fn {mod, counts} -> {mod, Enum.sum(counts)} end)
  end

  defp build_diagnostic(context_name, module, module_label, modal_label) do
    Diagnostic.info(@id,
      title: "Context drift — module's community differs from its context's modal",
      message:
        "#{inspect(module)} is in call-graph community #{inspect(module_label)}, but its " <>
          "declared context #{context_name} has modal community #{inspect(modal_label)}.",
      why:
        "Call-graph community detection groups modules by who-calls-whom. When a module " <>
          "lives in a different community than the bulk of its declared context, it usually " <>
          "means it's been over-coupled to a different part of the system, or that the " <>
          "context boundary was drawn at the wrong place.",
      alternatives: [
        Fix.new(
          summary: "Move the module to a context that matches its callers",
          detail:
            "Trace the module's outgoing calls — which OTHER context do they go to? That's " <>
              "usually where the module actually belongs.",
          applies_when: "When the module's role has shifted since the original context split."
        ),
        Fix.new(
          summary: "Refactor cross-context dependencies through the boundary",
          detail:
            "If the module SHOULD stay in this context, route its outgoing calls through " <>
              "the OTHER context's public API rather than reaching into its internals.",
          applies_when: "When the module's role is correct but its dependencies have leaked."
        )
      ],
      references: ["GUIDE.md#1.34"],
      context: %{module: module, module_community: module_label, modal_community: modal_label},
      file: "(compiled)",
      line: 0
    )
  end
end
