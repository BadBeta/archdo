defmodule Archdo.Rules.EventSourcing.AggregateMissingBehaviour do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Rules.EventSourcing.Helpers, as: ESHelpers

  @impl true
  def id, do: "8.8"

  @impl true
  def description,
    do: "Aggregate modules should `use Commanded.Aggregates.Aggregate` for lifecycle management"

  @impl true
  def analyze(file, ast, _opts) do
    if ESHelpers.aggregate_shape?(ast) and not ESHelpers.uses_aggregate_behaviour?(ast) and
         not ESHelpers.upcaster_module?(ast) do
      module_name = AST.extract_module_name(ast)

      [
        Diagnostic.info("8.8",
          title: "Aggregate without Commanded behaviour",
          message:
            "#{module_name} defines execute/2 and apply/2 but does not use Commanded.Aggregates.Aggregate",
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
              applies_when:
                "The module is a real aggregate that should participate in the command pipeline."
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
    else
      []
    end
  end
end
