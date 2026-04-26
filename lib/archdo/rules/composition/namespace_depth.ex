defmodule Archdo.Rules.Composition.NamespaceDepth do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @max_depth 4

  @impl true
  def id, do: "10.2"

  @impl true
  def description, do: "Module nesting should not exceed #{@max_depth} levels"

  @impl true
  def analyze(file, ast, _opts) do
    find_deep_modules(file, ast)
  end

  defp find_deep_modules(file, ast) do
    {_, results} =
      Macro.prewalk(ast, [], fn
        {:defmodule, meta, [{:__aliases__, _, aliases} | _]} = node, acc ->
          depth = length(aliases) - 1

          if depth > @max_depth do
            module_name = Enum.join(aliases, ".")

            diag =
              Diagnostic.info("10.2",
                title: "Excessive namespace depth",
                message: "#{module_name} has #{depth} nesting levels (limit: #{@max_depth})",
                why:
                  "Deeply nested module names tell you nothing about the domain — they describe a taxonomy, " <>
                    "not a concept. They make `alias` chains long, tab-completion painful, and usually mean " <>
                    "the project organizes code by file-type categories (Queries, Validators, Helpers) rather " <>
                    "than by what the modules actually do (Accounts, Billing, Notifications).",
                alternatives: [
                  Fix.new(
                    summary: "Flatten the namespace by removing taxonomy levels",
                    detail:
                      "Replace levels that describe what the module is (`Helpers`, `Queries`, `Validators`) " <>
                        "with the domain concept the module represents. The module ends up under the bounded " <>
                        "context that owns it, with no extra middle layers.",
                    applies_when:
                      "The deep levels describe technical taxonomy, not domain structure."
                  ),
                  Fix.new(
                    summary: "Accept the depth if it reflects real domain hierarchy",
                    detail:
                      "Some domains are genuinely nested (e.g. `MyApp.Billing.Invoicing.LineItems.Tax` for a " <>
                        "tax-engine sub-feature). If the levels mirror real domain concepts and not file-type " <>
                        "buckets, document it and add to freeze.",
                    applies_when: "The levels are genuine domain hierarchy."
                  )
                ],
                references: ["ARCHITECTURE_RULES.md#10.2"],
                context: %{module: module_name, depth: depth, threshold: @max_depth},
                file: file,
                line: AST.line(meta)
              )

            {node, [diag | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(results)
  end
end
