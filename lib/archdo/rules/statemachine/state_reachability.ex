defmodule Archdo.Rules.StateMachine.StateReachability do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{Diagnostic, Fix}

  @impl true
  def id, do: "9.1"

  @impl true
  def description, do: "All defined states must be reachable from initial states"

  @impl true
  def analyze(file, ast, _opts) do
    check_fsmx(file, ast) ++ check_ash_state_machine(file, ast)
  end

  # Check fsmx-style transition maps: %{"pending" => ["active", "cancelled"], ...}
  defp check_fsmx(file, ast) do
    {transitions, first_key} = find_fsmx_transitions_ordered(ast)

    if transitions == %{} do
      []
    else
      all_states = Archdo.Rules.StateMachine.Helpers.collect_all_states(transitions)
      # Use the first declared state as the initial state (fsmx convention)
      initial = MapSet.new([first_key])
      reachable = compute_reachable(initial, transitions)
      unreachable = MapSet.difference(all_states, reachable)

      unreachable
      |> MapSet.to_list()
      |> Enum.map(fn state ->
        Diagnostic.warning("9.1",
          title: "Unreachable state in state machine",
          message:
            "State `\"#{state}\"` is not reachable from the initial state `\"#{first_key}\"`",
          why:
            "An unreachable state is dead code: the entity can never enter it through any sequence of " <>
              "transitions, so the code that handles the state never runs and the test cases that exercise it " <>
              "are testing nothing. It's also a hint that the state diagram is incomplete or that the state " <>
              "was renamed and the old name was forgotten.",
          alternatives: [
            Fix.new(
              summary: "Add a transition that leads to the state",
              detail:
                "If the state is intentional, find which other state(s) should transition into it and add " <>
                  "the entries to the transitions map.",
              applies_when: "The state is part of the intended workflow."
            ),
            Fix.new(
              summary: "Delete the unreachable state",
              detail:
                "If the state is leftover from a refactor, remove it from the transitions map and any " <>
                  "associated handler functions.",
              applies_when: "The state is dead leftover code."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#9.1"],
          context: %{state: state, initial: to_string(first_key)},
          file: file,
          line: 1
        )
      end)
    end
  end

  defp check_ash_state_machine(_file, _ast), do: []

  # Returns {transitions_map, first_key} where first_key is the first
  # state declared in the map (fsmx convention for initial state)
  defp find_fsmx_transitions_ordered(ast) do
    {_, result} =
      Macro.prewalk(ast, {%{}, nil}, fn
        {:%, _, [{:__aliases__, _, _}, {:%{}, _, _pairs}]} = node, acc ->
          {node, acc}

        {:%{}, _, pairs} = node, {map, first} when is_list(pairs) ->
          if transition_map?(pairs) do
            new_map = Archdo.Rules.StateMachine.Helpers.pairs_to_transition_map(pairs)
            new_first = first || first_key_of(pairs)
            {node, {Map.merge(map, new_map), new_first}}
          else
            {node, {map, first}}
          end

        node, acc ->
          {node, acc}
      end)

    result
  end

  defp first_key_of([{{:__block__, _, [key]}, _} | _]), do: key
  defp first_key_of([{key, _} | _]), do: key
  defp first_key_of(_), do: nil

  defp transition_map?(pairs) do
    Enum.all?(pairs, fn
      {{:__block__, _, [key]}, list} when is_binary(key) and is_list(list) ->
        Enum.all?(list, fn
          {:__block__, _, [v]} when is_binary(v) -> true
          v when is_binary(v) -> true
          _ -> false
        end)
      {key, list} when is_binary(key) and is_list(list) -> true
      _ -> false
    end) and length(pairs) >= 2
  end

  defp compute_reachable(initial, transitions) do
    do_reachable(MapSet.to_list(initial), transitions, initial)
  end

  defp do_reachable([], _transitions, visited), do: visited

  defp do_reachable([state | rest], transitions, visited) do
    targets = Map.get(transitions, state, [])
    new = Enum.reject(targets, &MapSet.member?(visited, &1))
    do_reachable(new ++ rest, transitions, Enum.reduce(new, visited, &MapSet.put(&2, &1)))
  end
end
