defmodule Archdo.Rules.Boundary.ContextEncapsulation do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{Config, Diagnostic, Fix, Graph}

  @impl true
  def id, do: "1.2"

  @impl true
  def description, do: "External modules must not reach into a context's internal modules"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  def analyze_graph(%Graph{} = graph, %Config{} = config) do
    graph.edges
    |> Enum.filter(fn edge ->
      target_context = Config.owning_context(config, edge.target)
      source_context = Config.owning_context(config, edge.source)

      # Target is inside a context, but not the context's root module
      target_context != nil and
        # Source is outside that context
        source_context != target_context and
        # Target is an internal module (not the context root itself)
        internal_module?(edge.target, target_context)
    end)
    |> Enum.reject(fn edge -> tolerated?(edge, config) end)
    |> Enum.uniq_by(fn edge -> {edge.source, edge.target} end)
    |> Enum.map(fn edge ->
      target_context = Config.owning_context(config, edge.target)
      ctx_name = normalize(target_context)

      Diagnostic.warning("1.2",
        title: "Reach into context internals",
        message:
          "#{edge.source} calls into #{edge.target}, which is internal to #{ctx_name} and not part of its public API",
        why:
          "A bounded context exposes its capabilities through one public module (the 'context module') and " <>
            "hides its internal structure behind that. Direct calls into internal modules couple the caller to " <>
            "details that should be free to change — splitting a struct, renaming a query, moving code around. " <>
            "Once outside callers depend on internals, the boundary is gone in practice and refactoring becomes " <>
            "shotgun-surgery work.",
        alternatives: [
          Fix.new(
            summary: "Call the public function on the context module instead",
            detail:
              "If #{ctx_name} doesn't already expose what you need, add a public function there that wraps the " <>
                "internal call. Update the caller to use #{ctx_name}.<public_fn>. The context becomes the only " <>
                "thing the caller depends on and internal moves stop breaking it.",
            applies_when: "There is (or should be) a sensible public API for this operation."
          ),
          Fix.new(
            summary: "Promote the internal module to the context's public API",
            detail:
              "If the operation really needs to live as a separate module (e.g. a query module), document it " <>
                "as part of the context's public surface and place it directly under #{ctx_name} rather than in " <>
                "an internal subdirectory. The boundary stays explicit and the dependency is legitimate.",
            applies_when: "The internal module deserves to be public."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#1.2"],
        context: %{
          source: edge.source,
          target: edge.target,
          context: ctx_name
        },
        file: edge.file,
        line: edge.line
      )
    end)
  end

  defp internal_module?(target, context) do
    ctx_str = normalize(context)
    target_str = if is_binary(target), do: target, else: normalize(target)

    # The target is under the context namespace but is NOT the context itself
    target_str != ctx_str and String.starts_with?(target_str, ctx_str <> ".")
  end

  defp tolerated?(edge, _config) do
    # Schema references for struct matching are common
    String.ends_with?(edge.target, "Schema") or
      edge.type == :alias
  end

  defp normalize(mod) when is_atom(mod) do
    mod |> to_string() |> String.replace_leading("Elixir.", "")
  end

  defp normalize(mod) when is_binary(mod), do: mod
end
