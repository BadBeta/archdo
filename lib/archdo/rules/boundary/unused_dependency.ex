defmodule Archdo.Rules.Boundary.UnusedDependency do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  # File.read! IS the boundary work — this rule reads source files
  # to detect unused alias declarations by string comparison. There
  # is no substitutability hole: the file content IS the input.
  Module.register_attribute(__MODULE__, :archdo_volatility, persist: true)
  @archdo_volatility :stable

  @impl true
  def id, do: "4.6"

  @impl true
  def description, do: "No unnecessary module dependencies"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      find_unused_aliases(file, ast)
    end
  end

  defp find_unused_aliases(file, ast) do
    # Collect all alias declarations
    aliases = collect_aliases(ast)
    # Get the full source as string to check usage
    source = File.read!(file)

    for {short_name, full, line} <- aliases,
        unused_alias?(source, short_name) do
      Diagnostic.info("4.6",
        title: "Unused alias",
        message: "alias #{full} is declared but #{short_name} is never referenced",
        why:
          "Unused aliases create phantom dependencies: the file declares it depends on the module but never " <>
            "actually calls it. They survive across refactors, accumulate over time, and make the dependency " <>
            "graph misleading. Removing them is free maintenance.",
        alternatives: [
          Fix.new(
            summary: "Delete the alias declaration",
            detail:
              "Remove the `alias #{full}` line. The compiler will warn (and Credo flags) if a real reference " <>
                "needed it; this rule has already determined it's unreferenced.",
            applies_when: "The alias is genuinely unused (the rule already verified)."
          ),
          Fix.new(
            summary: "Verify the alias isn't used in a sigil or string",
            detail:
              "The detection counts string occurrences. If the short name is used inside a sigil, heredoc, or " <>
                "template, the rule may flag it as unused. Double-check before deleting.",
            applies_when: "The module name appears in non-code contexts."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#4.6"],
        context: %{alias: full, short: short_name},
        file: file,
        line: line
      )
    end
  end

  # Count how many times the short name appears (excluding the alias line itself).
  # A simple heuristic: if it appears only once, it's just the alias declaration.
  defp unused_alias?(source, short_name) do
    occurrences = length(String.split(source, short_name)) - 1
    occurrences <= 1
  end

  defp collect_aliases(ast) do
    {_, aliases} =
      Macro.prewalk(ast, [], fn
        {:alias, meta, [{:__aliases__, _, parts} | _opts]} = node, acc ->
          case AST.safe_concat(parts) do
            nil ->
              {node, acc}

            mod ->
              full = AST.module_name(mod)
              short = Atom.to_string(List.last(parts))
              line = AST.line(meta)
              {node, [{short, full, line} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(aliases)
  end
end
