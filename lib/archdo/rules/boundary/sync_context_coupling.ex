defmodule Archdo.Rules.Boundary.SyncContextCoupling do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix, FunctionGraph}

  @impl true
  def id, do: "1.13"

  @impl true
  def description,
    do: "Cross-context write operations should consider event-driven decoupling"

  @write_prefixes ~w(create update delete insert remove destroy upsert)

  @doc """
  Function-graph-based: detect cross-context calls to write operations.
  """
  def analyze_project(%FunctionGraph{}, []), do: []

  def analyze_project(%FunctionGraph{} = graph, contexts) when is_list(contexts) do
    do_analyze(graph, contexts)
  end

  defp do_analyze(graph, contexts) do
    context_strs =
      for ctx <- contexts,
          do: AST.module_name(ctx)

    graph.calls
    |> Enum.flat_map(&candidate_for_call(&1, context_strs))
    |> Enum.uniq_by(fn {call, _, _} ->
      {call.caller_module, call.target_module, call.target_fn}
    end)
    |> Enum.map(fn {call, caller_ctx, target_ctx} ->
      build_diagnostic(call, caller_ctx, target_ctx)
    end)
  end

  defp candidate_for_call(call, context_strs) do
    caller_ctx = Archdo.Config.owning_context(call.caller_module, context_strs)
    target_ctx = Archdo.Config.owning_context(call.target_module, context_strs)
    cross_context_candidate(call, caller_ctx, target_ctx)
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatches on the
  # context-pair shape; the cross-context guard fires only when both
  # contexts are known and distinct.
  defp cross_context_candidate(call, c, t) when not is_nil(c) and not is_nil(t) and c != t do
    domain_to_domain_write(
      interface_module?(call.caller_module),
      write_function?(call.target_fn),
      call,
      c,
      t
    )
  end

  defp cross_context_candidate(_call, _c, _t), do: []

  defp domain_to_domain_write(false, true, call, c, t), do: [{call, c, t}]
  defp domain_to_domain_write(_, _, _, _, _), do: []

  defp build_diagnostic(call, caller_ctx, target_ctx) do
    target_fn_str = "#{call.target_module}.#{call.target_fn}"

    Diagnostic.info("1.13",
      title: "Synchronous cross-context write coupling",
      message:
        "#{caller_ctx} calls #{target_fn_str}() synchronously — " <>
          "consider event-driven decoupling from #{target_ctx}",
      why:
        "When one context directly calls another context's write operations, the two " <>
          "are tightly coupled at runtime: the caller's success depends on the target being " <>
          "available and fast. If the target fails or is slow, the caller fails or blocks. " <>
          "Event-driven communication lets the caller fire-and-forget, and the target processes " <>
          "the write independently with its own error handling and retry logic.",
      alternatives: [
        Fix.new(
          summary: "Publish a domain event and let the target context subscribe",
          detail:
            "Instead of `#{target_fn_str}(attrs)`, publish an event like " <>
              "`Phoenix.PubSub.broadcast(MyApp.PubSub, \"events\", {:user_created, attrs})` " <>
              "and have #{target_ctx} subscribe and handle it.",
          applies_when: "The write can be eventually consistent."
        ),
        Fix.new(
          summary: "Use a background job for eventual consistency",
          detail:
            "Enqueue the cross-context write as an Oban/background job. The caller completes " <>
              "immediately and the target processes the write asynchronously with retries.",
          applies_when: "The write can be deferred and retried independently."
        ),
        Fix.new(
          summary: "Keep synchronous if transactional consistency is required",
          detail:
            "If both contexts must succeed or fail atomically (e.g., within a database " <>
              "transaction), synchronous coupling is the correct choice. Document the " <>
              "coupling reason.",
          applies_when: "ACID consistency across contexts is a hard requirement."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#1.13"],
      context: %{
        caller_context: caller_ctx,
        target_context: target_ctx,
        target_fn: to_string(call.target_fn)
      },
      file: call.file,
      line: call.line
    )
  end

  defp write_function?(func_name) do
    name = to_string(func_name)
    Enum.any?(@write_prefixes, &String.starts_with?(name, &1))
  end

  defp interface_module?(module_name) do
    String.contains?(module_name, "Web") or
      String.contains?(module_name, "Controller") or
      String.contains?(module_name, "LiveView") or
      String.contains?(module_name, "Live.") or
      String.ends_with?(module_name, "Router") or
      String.ends_with?(module_name, "Endpoint")
  end
end
