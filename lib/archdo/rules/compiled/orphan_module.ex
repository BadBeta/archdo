defmodule Archdo.Rules.Compiled.OrphanModule do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Compiled

  @impl true
  def id, do: "1.25"

  @impl true
  def description, do: "Orphan module — zero incoming and zero outgoing dependencies"

  @doc """
  Compiled-mode analysis: detect modules with no connections to the rest of the project.
  """
  @spec analyze_compiled(Compiled.t()) :: [Diagnostic.t()]
  def analyze_compiled(graph) do
    for mod <- Map.keys(Compiled.modules(graph)),
        orphan?(graph, mod) and
          not behaviour_definition?(mod, graph) and
          not application_entry_point?(mod) and
          not test_support_module?(mod),
        do: build_diagnostic(mod)
  end

  defp orphan?(graph, mod) do
    Compiled.module_dependencies(graph, mod) == [] and
      Compiled.module_dependents(graph, mod) == []
  end

  # Behaviour definitions are implemented by other modules, not called directly.
  # They define callbacks but may have zero function-level calls.
  defp behaviour_definition?(mod, graph) do
    case Map.get(Compiled.modules(graph), mod) do
      %{callback_fns: [_ | _]} -> true
      _ -> false
    end
  end

  # Application modules are entry points started by the runtime.
  defp application_entry_point?(mod) do
    mod_name = Atom.to_string(mod)

    String.ends_with?(mod_name, ".Application") or
      String.ends_with?(mod_name, ".MixProject")
  end

  # Test support modules (helpers, factories, fixtures) are called from test code
  # which is not in the project graph.
  defp test_support_module?(mod) do
    mod_name = Atom.to_string(mod)

    String.contains?(mod_name, "Test") or
      String.contains?(mod_name, "Factory") or
      String.contains?(mod_name, "Fixture") or
      String.contains?(mod_name, "Mock") or
      String.contains?(mod_name, "Support")
  end

  defp build_diagnostic(mod) do
    mod_name = AST.module_name(mod)

    Diagnostic.info("1.25",
      title: "Orphan module",
      message: "#{mod_name} has zero incoming and zero outgoing dependencies within the project",
      why:
        "A module with no connections to the rest of the project is either dead code, " <>
          "an entry point that should be wired into the supervision tree, or a utility " <>
          "that nothing uses yet. Orphan modules increase cognitive load without contributing " <>
          "to the system. If the module is used dynamically (via apply/3, protocol dispatch, " <>
          "or configuration), the static analysis may have missed the connection — verify " <>
          "before removing.",
      alternatives: [
        Fix.new(
          summary: "Delete if truly unused",
          detail:
            "Remove #{mod_name} entirely. Run `mix compile` and `mix test` to verify " <>
              "nothing breaks. Check for dynamic usage (apply/3, Module.concat) first.",
          applies_when: "The module is dead code left over from a refactor."
        ),
        Fix.new(
          summary: "Wire into the system if it's a new module",
          detail:
            "If #{mod_name} was recently added, ensure it's called from the appropriate " <>
              "context module or supervision tree.",
          applies_when: "The module is intended to be used but hasn't been connected yet."
        ),
        Fix.new(
          summary: "Add @moduledoc false if it's a support module",
          detail:
            "If this module is used only from tests or external tooling, it may be " <>
              "a false positive. Document its purpose with @moduledoc.",
          applies_when: "The module is called from outside the analyzed paths."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#1.25"],
      context: %{
        module: mod_name
      },
      file: "lib",
      line: 0
    )
  end
end
