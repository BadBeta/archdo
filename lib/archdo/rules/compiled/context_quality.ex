defmodule Archdo.Rules.Compiled.ContextQuality do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Compiled

  @impl true
  def id, do: "1.23"

  @impl true
  def description, do: "Context boundary quality — cohesion, coupling, and encapsulation analysis"

  # Minimum members to consider a context worth analyzing
  @min_members 3
  # Context with leak ratio above this is flagged
  @leak_threshold 0.5
  # Context with cohesion below this is flagged
  @cohesion_threshold 0.3
  @spec analyze_compiled(Compiled.t()) :: [Diagnostic.t()]
  def analyze_compiled(graph) do
    contexts = Compiled.discover_contexts(graph)

    context_diagnostics =
      contexts
      |> Enum.filter(fn ctx -> length(ctx.members) >= @min_members end)
      |> Enum.flat_map(fn ctx ->
        issues = []

        # Check for high leak ratio
        issues =
          case ctx.incoming_calls > 0 and ctx.leak_calls / ctx.incoming_calls > @leak_threshold do
            true -> [build_leak_diagnostic(ctx) | issues]
            false -> issues
          end

        # Check for low cohesion
        issues =
          case ctx.cohesion < @cohesion_threshold and
                 ctx.internal_calls + ctx.incoming_calls + ctx.outgoing_calls > 10 do
            true -> [build_cohesion_diagnostic(ctx) | issues]
            false -> issues
          end

        # Check for misplaced modules
        misplaced_diags =
          Enum.map(ctx.misplaced_modules, fn m -> build_misplaced_diagnostic(ctx.context, m) end)

        issues ++ misplaced_diags
      end)

    # Also report a summary diagnostic if no contexts have boundary modules
    no_boundary =
      contexts
      |> Enum.filter(fn ctx ->
        length(ctx.members) >= @min_members and ctx.boundary_module == nil
      end)
      |> Enum.map(&build_no_boundary_diagnostic/1)

    context_diagnostics ++ no_boundary
  end

  defp build_leak_diagnostic(ctx) do
    leak_ratio = Float.round(ctx.leak_calls / max(ctx.incoming_calls, 1) * 100, 0)

    leaking =
      ctx.leaking_modules
      |> Enum.take(5)
      |> Enum.map_join(", ", fn m -> AST.module_name(m.module) end)

    Diagnostic.warning("1.23",
      title: "Context boundary leak",
      message:
        "#{ctx.context} — #{trunc(leak_ratio)}% of incoming calls bypass the boundary module " <>
          "(#{ctx.leak_calls} leaks of #{ctx.incoming_calls} incoming calls)",
      why:
        "External modules call internal members of #{ctx.context} directly instead " <>
          "of going through the boundary module" <>
          boundary_note(ctx.boundary_module) <>
          ". Leaking modules: #{leaking}. " <>
          "This breaks encapsulation — internal changes can break external callers. " <>
          "Compiled analysis confirms these are ground-truth calls after macro expansion.",
      alternatives: [
        Fix.new(
          summary: "Route external calls through the boundary module",
          detail:
            "Add public functions to #{ctx.context} that delegate to internal modules. " <>
              "External callers should only call #{ctx.context}.function(), never " <>
              "#{ctx.context}.Internal.function().",
          applies_when: "The context has a clear public API."
        ),
        Fix.new(
          summary: "Promote leaking modules to public API",
          detail:
            "If #{leaking} are intentionally public, make them sibling modules " <>
              "rather than children of #{ctx.context}.",
          applies_when: "The leaking modules serve a cross-cutting concern."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#1.23"],
      context: %{
        context: ctx.context,
        leak_ratio: leak_ratio,
        leak_calls: ctx.leak_calls,
        incoming_calls: ctx.incoming_calls,
        cohesion: ctx.cohesion,
        coupling: ctx.coupling
      },
      file: "lib",
      line: 0
    )
  end

  defp build_cohesion_diagnostic(ctx) do
    Diagnostic.info("1.23",
      title: "Low context cohesion",
      message:
        "#{ctx.context} — cohesion #{ctx.cohesion} (#{ctx.internal_calls} internal calls " <>
          "vs #{ctx.outgoing_calls} outgoing, #{ctx.incoming_calls} incoming)",
      why:
        "Modules in #{ctx.context} call outside the context more than they call each other. " <>
          "Low cohesion suggests the context may be too broad (grouping unrelated modules), " <>
          "or that modules are misplaced and belong in a different context. " <>
          "A well-defined context has high internal cohesion — most calls stay within the boundary.",
      alternatives: [
        Fix.new(
          summary: "Split into smaller, more focused contexts",
          detail:
            "Identify clusters of tightly-connected modules within #{ctx.context} and " <>
              "extract them into separate contexts.",
          applies_when: "The context contains multiple unrelated concerns."
        ),
        Fix.new(
          summary: "Move misplaced modules to their natural context",
          detail:
            "Check the misplaced_modules list — these modules have stronger " <>
              "affinity to a different context.",
          applies_when: "Some modules clearly belong elsewhere."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#1.23"],
      context: %{
        context: ctx.context,
        cohesion: ctx.cohesion,
        coupling: ctx.coupling,
        internal_calls: ctx.internal_calls,
        outgoing_calls: ctx.outgoing_calls,
        incoming_calls: ctx.incoming_calls,
        member_count: length(ctx.members)
      },
      file: "lib",
      line: 0
    )
  end

  defp build_misplaced_diagnostic(context_name, misplaced) do
    mod_name = AST.module_name(misplaced.module)

    Diagnostic.info("1.23",
      title: "Misplaced module",
      message:
        "#{mod_name} is in #{context_name} but calls #{misplaced.calls_to_other} external modules " <>
          "vs #{misplaced.calls_to_own} internal — strongest affinity to #{misplaced.strongest_affinity}",
      why:
        "This module calls more functions in other contexts than in its own. " <>
          "It has the strongest call-graph affinity to #{misplaced.strongest_affinity}, " <>
          "suggesting it may belong there instead of #{context_name}. Misplaced modules " <>
          "reduce context cohesion and create unnecessary cross-boundary dependencies.",
      alternatives: [
        Fix.new(
          summary: "Move to #{misplaced.strongest_affinity}",
          detail:
            "Rename #{mod_name} to #{misplaced.strongest_affinity}.#{AST.short_name(misplaced.module)}. " <>
              "Update all callers.",
          applies_when: "The module's functionality belongs in the other context."
        ),
        Fix.new(
          summary: "Keep and refactor to reduce cross-context calls",
          detail:
            "If the module belongs in #{context_name}, reduce its external dependencies " <>
              "by injecting cross-context data through parameters instead of calling out.",
          applies_when: "The module belongs here but has too many external dependencies."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#1.23"],
      context: %{
        module: mod_name,
        context: context_name,
        calls_internal: misplaced.calls_to_own,
        calls_external: misplaced.calls_to_other,
        strongest_affinity: misplaced.strongest_affinity
      },
      file: "lib",
      line: 0
    )
  end

  defp build_no_boundary_diagnostic(ctx) do
    Diagnostic.info("1.23",
      title: "Context without boundary module",
      message:
        "#{ctx.context} has #{length(ctx.members)} modules but no boundary module " <>
          "(expected: #{ctx.context} as the public API)",
      why:
        "A context should have a boundary module with the same name as the context " <>
          "(e.g., MyApp.Accounts for the Accounts context). This module serves as the " <>
          "public API — external callers go through it, internal modules are hidden. " <>
          "Without a boundary module, there's no clear entry point and encapsulation " <>
          "is not enforceable.",
      alternatives: [
        Fix.new(
          summary: "Create a boundary module",
          detail:
            "Create #{ctx.context} with public functions that delegate to " <>
              "internal modules. Mark internal modules with @moduledoc false.",
          applies_when: "The context should have a public API."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#1.23"],
      context: %{
        context: ctx.context,
        member_count: length(ctx.members)
      },
      file: "lib",
      line: 0
    )
  end

  defp boundary_note(nil), do: " (no boundary module found)"
  defp boundary_note(mod), do: " (#{AST.module_name(mod)})"
end
