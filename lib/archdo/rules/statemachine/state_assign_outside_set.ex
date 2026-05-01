defmodule Archdo.Rules.StateMachine.StateAssignOutsideSet do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — SM-D. An assignment to a `state:` field
  # whose value is a literal atom not in the module's `@states [...]`
  # declaration. Assigns a state the rest of the code doesn't know how
  # to handle, leading to FunctionClauseError or silent misbehaviour
  # the next time the state is dispatched on. Rule is opt-in via
  # `@states` declaration.

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Rules.StateMachine.Helpers

  @impl true
  def id, do: "SM-D"

  @impl true
  def description,
    do: "Assignment to `state:` with literal atom not in module's @states set"

  @impl true
  def analyze(file, ast, _opts) do
    case Helpers.declared_states(ast) do
      nil -> []
      states -> find_bad_assignments(file, ast, states)
    end
  end

  defp find_bad_assignments(file, ast, states) do
    {_, found} =
      Macro.prewalk(ast, [], fn node, acc ->
        {node, extract_state_assigns(node) ++ acc}
      end)

    found
    |> Enum.reject(fn {value, _line} -> MapSet.member?(states, value) end)
    |> Enum.reverse()
    |> Enum.map(fn {value, line} -> build_diagnostic(file, line, value, states) end)
  end

  # `state:` keyword pair appears in maps, structs, struct updates.
  # Match both the literal_encoder-wrapped and bare forms; only fire
  # when the value is a literal atom (not a variable or computed
  # expression — that's SM-E territory).
  defp extract_state_assigns(node) do
    Enum.flat_map(state_pairs_in(node), fn
      {{:__block__, _, [:state]}, {:__block__, meta, [value]}} when is_atom(value) ->
        [{value, AST.line(meta)}]

      {:state, {:__block__, meta, [value]}} when is_atom(value) ->
        [{value, AST.line(meta)}]

      {{:__block__, _, [:state]}, value} when is_atom(value) and not is_nil(value) ->
        [{value, 0}]

      {:state, value} when is_atom(value) and not is_nil(value) ->
        [{value, 0}]

      _ ->
        []
    end)
  end

  # Find `state:` keyword pairs anywhere a 2-tuple appears in the node.
  defp state_pairs_in({_, _, args}) when is_list(args) do
    Enum.flat_map(args, &collect_pairs/1)
  end

  defp state_pairs_in(list) when is_list(list), do: Enum.flat_map(list, &collect_pairs/1)
  defp state_pairs_in(_), do: []

  defp collect_pairs({key, _value} = pair) when is_atom(key), do: [pair]

  defp collect_pairs({{:__block__, _, [key]}, _value} = pair) when is_atom(key), do: [pair]

  defp collect_pairs(list) when is_list(list), do: Enum.flat_map(list, &collect_pairs/1)
  defp collect_pairs(_), do: []

  defp build_diagnostic(file, line, value, states) do
    Diagnostic.warning("SM-D",
      title: "State assignment outside declared @states",
      message:
        "Assigns `state: #{inspect(value)}` — value not in @states " <>
          "(allowed: #{inspect(MapSet.to_list(states))})",
      why:
        "Assigns a state the rest of the code doesn't know how to handle, leading " <>
          "to FunctionClauseError or silent misbehaviour the next time the state " <>
          "is dispatched on.",
      alternatives: [
        Fix.new(
          summary: "Correct the assigned value",
          detail: "Use one of the declared states.",
          applies_when: "The assignment was a typo."
        ),
        Fix.new(
          summary: "Declare the new state",
          detail: "If the new value is legitimate, add it to @states.",
          applies_when: "The state machine is gaining a new state."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#SM-D"],
      context: %{value: value, declared: MapSet.to_list(states)},
      file: file,
      line: line
    )
  end
end
