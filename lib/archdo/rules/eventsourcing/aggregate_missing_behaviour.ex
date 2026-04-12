defmodule Archdo.Rules.EventSourcing.AggregateMissingBehaviour do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "8.8"

  @impl true
  def description, do: "Aggregate modules should `use Commanded.Aggregates.Aggregate` for lifecycle management"

  @impl true
  def analyze(file, ast, _opts) do
    if not aggregate_shape?(ast) or uses_aggregate_behaviour?(ast) or upcaster_module?(ast) do
      []
    else
      module_name = AST.extract_module_name(ast)

      [
        Diagnostic.info("8.8",
          title: "Aggregate without Commanded behaviour",
          message: "#{module_name} defines execute/2 and apply/2 but does not use Commanded.Aggregates.Aggregate",
          why:
            "A module that walks like an aggregate (command handler + event applier) but does not declare itself " <>
              "as one is invisible to the framework: no GenServer wrapper, no snapshotting, no router registration, " <>
              "and the linter and dialyzer can't check the callback shapes against the behaviour.",
          alternatives: [
            Fix.new(
              summary: "Declare the module as a Commanded aggregate",
              detail:
                "Add `use Commanded.Aggregates.Aggregate` near the top of the module. The framework then takes " <>
                  "over lifecycle management, the router can dispatch commands to it, and the behaviour callbacks " <>
                  "are checked at compile time.",
              example: """
              ```elixir
              defmodule #{module_name} do
                use Commanded.Aggregates.Aggregate
                # execute/2 and apply/2 ...
              end
              ```
              """,
              applies_when: "The module is a real aggregate that should participate in the command pipeline."
            ),
            Fix.new(
              summary: "Rename the functions if the module is not an aggregate",
              detail:
                "If the module just happens to expose `execute/2` and `apply/2` for unrelated reasons (e.g. a " <>
                  "policy object, a service module), rename one of them so the rule stops matching the aggregate shape.",
              applies_when: "The module is not part of the event sourcing pipeline."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#8.8"],
          context: %{module: module_name},
          file: file,
          line: 1
        )
      ]
    end
  end

  # An "aggregate shape" is a module that defines both execute/2 and apply/2.
  defp aggregate_shape?(ast) do
    fns = AST.extract_functions(ast, :public)
    has_execute = Enum.any?(fns, fn {n, a, _, _, _} -> n == :execute and a == 2 end)
    has_apply = Enum.any?(fns, fn {n, a, _, _, _} -> n == :apply and a == 2 end)
    has_execute and has_apply
  end

  defp uses_aggregate_behaviour?(ast) do
    AST.contains?(ast, fn
      {:use, _, [{:__aliases__, _, [:Commanded, :Aggregates, :Aggregate]} | _]} -> true
      _ -> false
    end)
  end

  defp upcaster_module?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {:defmodule, _, [{:__aliases__, _, aliases} | _]} = node, _acc ->
          parts = Enum.map(aliases, &Atom.to_string/1)
          is_upcaster = Enum.any?(parts, fn p -> String.contains?(String.downcase(p), "upcast") end)
          {node, is_upcaster}

        node, acc ->
          {node, acc}
      end)

    found?
  end
end
