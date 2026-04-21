defmodule Archdo.Rules.Boundary.ChattyBoundary do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix, FunctionGraph}

  # Two contexts that talk more than this are suspiciously chatty
  @warn_chatter 15
  @error_chatter 40

  @impl true
  def id, do: "1.10"

  @impl true
  def description, do: "Chatty boundaries — two contexts that call each other often are in the wrong place"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc """
  Graph-based: count cross-context calls. High call volume between two contexts
  suggests they're actually one concept that was split incorrectly.
  """
  def analyze_project(%FunctionGraph{} = graph, contexts) when is_list(contexts) do
    if contexts == [] do
      []
    else
      do_analyze(graph, contexts)
    end
  end

  defp do_analyze(graph, contexts) do
    context_strs =
      Enum.map(contexts, &AST.module_name/1)

    # Count distinct call pairs between contexts
    cross_calls =
      graph.calls
      |> Enum.map(fn call ->
        caller_ctx = Archdo.Config.owning_context(call.caller_module, context_strs)
        target_ctx = Archdo.Config.owning_context(call.target_module, context_strs)
        {caller_ctx, target_ctx, call}
      end)
      |> Enum.filter(fn {a, b, _} -> a != nil and b != nil and a != b end)
      |> Enum.group_by(
        fn {a, b, _} -> pair_key(a, b) end,
        fn {_, _, call} -> call end
      )

    cross_calls
    |> Enum.filter(fn {_pair, calls} -> length(calls) >= @warn_chatter end)
    |> Enum.map(fn {{ctx_a, ctx_b}, calls} ->
      count = length(calls)
      first_call = hd(calls)
      build_chatty_diag(ctx_a, ctx_b, count, first_call)
    end)
  end

  defp build_chatty_diag(ctx_a, ctx_b, count, first_call) do
    severity_fun = if count >= @error_chatter, do: &Diagnostic.warning/2, else: &Diagnostic.info/2

    severity_fun.("1.10",
      title: "Chatty boundary between contexts",
      message: "#{ctx_a} and #{ctx_b} have #{count} cross-context call edges",
      why:
        "When two contexts call each other constantly, the boundary stops carrying its weight: the modules " <>
          "are coupled in practice but you pay for the indirection of going through the public APIs. Heavy " <>
          "chatter is usually a sign that the two contexts are really one concept that was split prematurely, " <>
          "or that an underlying shared concept wants to be extracted into its own context.",
      alternatives: [
        Fix.new(
          summary: "Merge the two contexts into one",
          detail:
            "If the chatter happens because every operation in one always invokes operations in the other, " <>
              "the boundary is fictional. Move the smaller context's modules into the larger one and delete " <>
              "the cross-context API.",
          applies_when: "The chatter spans most of both contexts and merging produces a coherent whole."
        ),
        Fix.new(
          summary: "Extract a shared subdomain that both depend on",
          detail:
            "If the chatter is concentrated on one shared concept (an entity, a query, a calculation), " <>
              "extract that concept into a third context that both originals depend on. The cross-edges " <>
              "between the originals disappear in favor of a tree-shaped dependency.",
          applies_when: "Most calls touch one shared concept rather than the whole context."
        ),
        Fix.new(
          summary: "Keep them separate but bulk-up the API",
          detail:
            "If the chatter is N small calls that could be one bigger call (e.g. fetching 50 individual " <>
              "items in a loop instead of `list_by_ids/1`), reshape the public API to do the work in one " <>
              "trip. The fan-in count drops without merging.",
          applies_when: "The chatter is mostly N+1-style fine-grained calls."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#1.10"],
      context: %{contexts: [ctx_a, ctx_b], call_count: count},
      file: first_call.file,
      line: first_call.line
    )
  end

  # Stable pair key (alphabetical) so (A, B) and (B, A) group together
  defp pair_key(a, b) when a <= b, do: {a, b}
  defp pair_key(a, b), do: {b, a}
end
