defmodule Archdo.Rules.Boundary.FunctionBoundary do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{Diagnostic, Fix, FunctionGraph}

  @impl true
  def id, do: "1.7"

  @impl true
  def description, do: "Cross-context calls must target the receiving context's public API"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc """
  Project-level: walk the function graph and flag cross-context calls
  that hit non-API functions.
  """
  def analyze_project(%FunctionGraph{} = graph, contexts) do
    graph.calls
    |> Enum.filter(fn call ->
      cross_context_violation?(call, contexts, graph)
    end)
    |> Enum.uniq_by(fn call ->
      {call.caller_module, call.target_module, call.target_fn, call.target_arity}
    end)
    |> Enum.map(fn call ->
      target_context = Archdo.Config.owning_context(call.target_module, contexts)

      Diagnostic.warning("1.7",
        title: "Cross-context call to non-API function",
        message:
          "#{call.caller_module} calls #{call.target_module}.#{call.target_fn}/#{call.target_arity} which is not part of #{target_context}'s public API",
        why:
          "The whole point of having #{target_context} as a bounded context is that the rest of the system " <>
            "talks to it through one published surface — the context module. Calling internal sub-modules " <>
            "directly couples the caller to internal structure that should be free to change. Once outside " <>
            "callers depend on internals, every refactor inside #{target_context} becomes a multi-module change.",
        alternatives: [
          Fix.new(
            summary: "Call the equivalent function on the context root #{target_context}",
            detail:
              "Look for an existing public function on #{target_context} that does what you need. If it " <>
                "exists, switch the call site. The internal module stays internal and the caller depends only " <>
                "on the public API.",
            applies_when: "An equivalent public function already exists."
          ),
          Fix.new(
            summary:
              "Add `#{call.target_fn}/#{call.target_arity}` to #{target_context} as a delegated public API",
            detail:
              "If no public function exists yet, add one to #{target_context} that wraps the internal call " <>
                "(often a single `defdelegate`). Update the caller to use it. The new function becomes part of " <>
                "the documented public surface.",
            applies_when: "The operation is legitimately needed by other contexts."
          ),
          Fix.new(
            summary: "Move the calling logic into #{target_context}",
            detail:
              "Sometimes the cleanest fix is to move the function that needs the internal call into the " <>
                "owning context — the dependency disappears entirely.",
            applies_when: "The caller's logic actually belongs inside the target context."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#1.7"],
        context: %{
          caller: call.caller_module,
          target: "#{call.target_module}.#{call.target_fn}/#{call.target_arity}",
          context: target_context
        },
        file: call.file,
        line: call.line
      )
    end)
  end

  defp cross_context_violation?(call, contexts, graph) do
    target_context = Archdo.Config.owning_context(call.target_module, contexts)
    caller_context = Archdo.Config.owning_context(call.caller_module, contexts)

    cond do
      # Target is not in any tracked context
      target_context == nil ->
        false

      # Same context — internal calls are OK
      caller_context == target_context ->
        false

      # Target is the context root itself (e.g., MyApp.Accounts.list_users) — public API
      call.target_module == target_context ->
        # But verify the function is actually defined as public in the context root
        not function_exists_in_module?(graph, target_context, call.target_fn, call.target_arity) or
          not public_in_root?(graph, target_context, call.target_fn, call.target_arity)

      # Target is a sub-module of the context — internal, this is a violation
      true ->
        true
    end
  end

  defp function_exists_in_module?(graph, module, name, arity) do
    Map.has_key?(graph.definitions, {module, name, arity})
  end

  defp public_in_root?(graph, module, name, arity) do
    case Map.get(graph.definitions, {module, name, arity}) do
      %{visibility: :public} -> true
      _ -> false
    end
  end
end
