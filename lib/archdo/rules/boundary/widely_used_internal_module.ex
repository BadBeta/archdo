defmodule Archdo.Rules.Boundary.WidelyUsedInternalModule do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-implementing: §10.1 — sister rule to 2.3
  # (private_module_calls). 2.3 fires per call edge; 1.27 fires per
  # MODULE when ≥ 3 distinct caller contexts reach a `@moduledoc false`
  # target. Signal: the marker is lying — the module is de facto
  # public infrastructure. Three remediations (move to shared kernel /
  # facade through owning context / promote to public) are documented
  # in the implementing skill's §10.1 subsection.

  alias Archdo.{AST, Diagnostic, Fix, Graph}

  @impl true
  def id, do: "1.27"

  @impl true
  def description,
    do:
      "@moduledoc false module is reached by many caller contexts — likely public infrastructure"

  @default_threshold 3

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc """
  Project-level analysis. Fires one diagnostic per `@moduledoc false`
  module whose call-site set spans `:threshold` or more distinct
  caller contexts (default 3). Test/* callers are excluded from the
  count — they don't represent production reach.

  `caller_context/1` extracts the 2-component prefix (`MyApp.Foo` for
  `MyApp.Foo.X.Y`); modules whose name has fewer than 2 components
  are returned unchanged. Multiple callers from the same context
  count as one toward the threshold.
  """
  @spec analyze_project([{String.t(), Macro.t()}], keyword()) :: [Diagnostic.t()]
  def analyze_project(file_asts, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, @default_threshold)

    production = Enum.reject(file_asts, fn {file, _} -> AST.test_file?(file) end)
    private_modules = collect_private_modules(production)

    case MapSet.size(private_modules) do
      0 -> []
      _ -> find_widely_used(production, private_modules, threshold)
    end
  end

  @doc "Pure helper — extract the 'context' key from a module name."
  @spec caller_context(String.t()) :: String.t()
  def caller_context(name) when is_binary(name) do
    case String.split(name, ".") do
      [single] -> single
      [a, b | _] -> a <> "." <> b
    end
  end

  defp collect_private_modules(production) do
    for {_file, ast} <- production,
        AST.internal_module?(ast),
        module = AST.extract_module_name(ast),
        module != "Unknown",
        into: MapSet.new(),
        do: module
  end

  defp find_widely_used(production, private_modules, threshold) do
    graph = Graph.build(production)

    graph.edges
    |> Enum.filter(fn edge ->
      edge.type == :call and MapSet.member?(private_modules, edge.target)
    end)
    |> Enum.group_by(& &1.target)
    |> Enum.flat_map(fn {target, edges} ->
      caller_contexts =
        edges
        |> Enum.map(&caller_context(&1.source))
        |> Enum.uniq()
        |> Enum.reject(fn ctx -> ctx == caller_context(target) end)

      maybe_diagnostic(target, caller_contexts, edges, threshold)
    end)
  end

  # §§ elixir-implementing: §5.2 — multi-clause head, no if/else.
  defp maybe_diagnostic(target, caller_contexts, edges, threshold) do
    case length(caller_contexts) >= threshold do
      true -> [build_diagnostic(target, caller_contexts, edges)]
      false -> []
    end
  end

  defp build_diagnostic(target, caller_contexts, edges) do
    count = length(caller_contexts)
    contexts_text = caller_contexts |> Enum.sort() |> Enum.join(", ")
    {first_file, first_line} = first_call_site(edges)

    Diagnostic.info("1.27",
      title: "@moduledoc false module is widely used",
      message:
        "#{target} is marked `@moduledoc false` but is called from #{count} distinct " <>
          "caller contexts (#{contexts_text}). The marker is lying — the module is " <>
          "de facto public infrastructure. Reconcile intent and reality.",
      why:
        "When ≥ 3 unrelated contexts reach into one `@moduledoc false` module, the " <>
          "abstraction is real and shared; only its location is wrong. Three responses " <>
          "(move to shared kernel / facade through owning context / promote to public) " <>
          "are documented in `elixir-implementing` §10.1's subsection \"When an " <>
          "@moduledoc false module is widely used.\" Pick by signal, not by reflex.",
      alternatives: [
        Fix.new(
          summary: "Move to shared kernel — keep at top level OR under MyApp.Shared",
          detail:
            "When no single context owns the abstraction (the typical case at this " <>
              "scale), keep the module at its top-level location and replace " <>
              "`@moduledoc false` with a real moduledoc that documents it as " <>
              "project-wide infrastructure. The marker comes off; the call sites " <>
              "stay. Alternative: move under `MyApp.Shared.<Name>` if you want the " <>
              "shared status to be visible in the namespace.",
          applies_when:
            "The module is at top level OR ≥ 3 contexts use it, AND there is no clear " <>
              "domain owner."
        ),
        Fix.new(
          summary: "Facade through one owning context",
          detail:
            "If one context plausibly owns the abstraction, add public functions on " <>
              "that context that delegate (`defdelegate`) or wrap (telemetry, logging). " <>
              "The internal module stays `@moduledoc false`; consumers reach it only " <>
              "through the parent. Avoid pure-ceremony delegation (`defdelegate :every_function`).",
          applies_when:
            "One context plausibly owns the abstraction and a thin defdelegate wrapper " <>
              "is acceptable."
        ),
        Fix.new(
          summary: "Promote to public — replace @moduledoc false with a real moduledoc",
          detail:
            "When you're committing to back-compat for the function set, replace the " <>
              "marker with a real moduledoc documenting API stability. Heaviest " <>
              "commitment of the three — locks the function set in place; renames and " <>
              "signature changes are now breaking.",
          applies_when:
            "The module IS the API many consumers genuinely need AND its internals " <>
              "are unlikely to evolve."
        )
      ],
      tags: [:boundary, :architecture],
      context: %{
        target: target,
        caller_contexts: caller_contexts,
        caller_context_count: count
      },
      file: first_file,
      line: first_line
    )
  end

  defp first_call_site(edges) do
    case edges do
      [edge | _] -> {edge.file, edge.line}
      _ -> {"(project)", 1}
    end
  end
end
