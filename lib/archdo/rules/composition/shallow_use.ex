defmodule Archdo.Rules.Composition.ShallowUse do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @max_use_statements 2

  # Standard uses that don't count toward the limit
  @standard_uses ~w(
    GenServer Agent Supervisor DynamicSupervisor Task
    ExUnit.Case ExUnit.CaseTemplate
    Phoenix.Controller Phoenix.LiveView Phoenix.LiveComponent Phoenix.Component Phoenix.Channel
    Ecto.Schema Ecto.Migration
    Plug.Builder Plug.Router
    Application
  )

  @impl true
  def id, do: "10.1"

  @impl true
  def description, do: "Prefer composition over deep `use` chains"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      check_modules(file, ast)
    end
  end

  defp check_modules(file, ast) do
    {_, results} =
      Macro.prewalk(ast, [], fn
        {:defmodule, meta, [{:__aliases__, _, aliases}, [do: body]]} = node, acc ->
          module_name = Module.concat(aliases) |> Atom.to_string() |> String.replace_leading("Elixir.", "")
          non_standard = count_non_standard_uses(body)

          if non_standard > @max_use_statements do
            diag =
              Diagnostic.info("10.1",
                title: "Deep `use` chain",
                message:
                  "#{module_name} has #{non_standard} non-standard `use` statements (limit: #{@max_use_statements})",
                why:
                  "Deep `use` chains are the functional equivalent of multiple inheritance. Each `use` injects " <>
                    "functions, attributes, and `__using__` macros into the module's scope, but the reader can't " <>
                    "see what was added without reading every `__using__` body. The implicit coupling makes " <>
                    "refactors fragile and overrides surprising — you don't know what you're overriding.",
                alternatives: [
                  Fix.new(
                    summary: "Use explicit `import` and `alias` instead of `use`",
                    detail:
                      "If `use Foo` only injects functions you call, replace it with `import Foo, only: [...]` " <>
                        "or `alias Foo`. The dependency stays visible at the call site and the magic disappears.",
                    applies_when: "The `use`d modules don't actually need macro injection."
                  ),
                  Fix.new(
                    summary: "Compose with behaviours instead of `use` chains",
                    detail:
                      "If the goal is to share behaviour, declare a `@behaviour` and have the module implement " <>
                        "the callbacks explicitly. The contract is documented and overrides are visible.",
                    applies_when: "The pattern is shared behaviour, not shared implementation."
                  )
                ],
                references: ["ARCHITECTURE_RULES.md#10.1"],
                context: %{module: module_name, use_count: non_standard, threshold: @max_use_statements},
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

  defp count_non_standard_uses(body) do
    {_, uses} =
      Macro.prewalk(body, [], fn
        {:use, _, [{:__aliases__, _, aliases} | _]} = node, acc ->
          mod = Module.concat(aliases) |> Atom.to_string() |> String.replace_leading("Elixir.", "")

          if mod in @standard_uses do
            {node, acc}
          else
            {node, [mod | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    length(uses)
  end

end
