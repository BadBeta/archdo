defmodule Archdo.Rules.StateMachine.TerminalStateIntegrity do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{Diagnostic, Fix}
  alias Archdo.Rules.StateMachine.Helpers

  @impl true
  def id, do: "9.2"

  @impl true
  def description, do: "Terminal states should have no outgoing transitions (except self-loops)"

  @impl true
  def analyze(file, ast, _opts) do
    transitions = find_fsmx_transitions(ast)

    if transitions == %{} do
      []
    else
      find_terminal_violations(file, transitions)
    end
  end

  defp find_terminal_violations(file, transitions) do
    all_states =
      transitions
      |> Helpers.collect_all_states()
      |> MapSet.to_list()

    # Find states that reach a "terminal-looking" state and themselves have no other exits
    # Actually, the more practical check: states named like terminal states
    # (completed, cancelled, failed, terminated, done, closed, archived)
    # that have outgoing transitions to non-self states
    terminal_names =
      ~w(completed cancelled failed terminated done closed archived deleted expired)

    for state <- all_states,
        String.downcase(state) in terminal_names,
        has_non_self_transitions?(state, transitions) do
      targets = Map.get(transitions, state, [])

      Diagnostic.warning("9.2",
        title: "Terminal state with outgoing transitions",
        message:
          "State `\"#{state}\"` has the name of a terminal state but defines transitions to #{inspect(targets)}",
        why:
          "States named like `completed`, `cancelled`, `failed` are conventionally terminal — once entered, " <>
            "they shouldn't transition out. A terminal state with outgoing edges either means the state isn't " <>
            "really terminal (and the name is misleading) or the transitions are bugs that let entities resurrect " <>
            "from a final state. Either way, the state diagram is inconsistent with itself.",
        alternatives: [
          Fix.new(
            summary: "Remove the outgoing transitions if the state is genuinely terminal",
            detail:
              "Delete the entry from the transitions map. Self-loops (e.g. for idempotent retries) are " <>
                "acceptable; outbound edges to other states are not.",
            applies_when: "The state really is terminal."
          ),
          Fix.new(
            summary: "Rename the state if it isn't actually terminal",
            detail:
              "If entities can legitimately move out of the state, the name is misleading. Rename it to " <>
                "something that reflects its true role (e.g. `awaiting_review` instead of `completed`).",
            applies_when: "The state has legitimate outgoing transitions."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#9.2"],
        context: %{state: state, targets: targets},
        file: file,
        line: 1
      )
    end
  end

  defp has_non_self_transitions?(state, transitions) do
    targets = Map.get(transitions, state, [])
    Enum.any?(targets, &(&1 != state))
  end

  # Reuse the same transition map detection logic from StateReachability
  defp find_fsmx_transitions(ast) do
    {_, transitions} =
      Macro.prewalk(ast, %{}, fn
        {:%, _, [{:__aliases__, _, _}, {:%{}, _, _pairs}]} = node, acc ->
          {node, acc}

        {:%{}, _, pairs} = node, acc when is_list(pairs) ->
          if transition_map?(pairs) do
            map = Helpers.pairs_to_transition_map(pairs)
            {node, Map.merge(acc, map)}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    transitions
  end

  defp transition_map?(pairs) do
    Enum.all?(pairs, fn
      {{:__block__, _, [key]}, list} when is_binary(key) and is_list(list) -> true
      {key, list} when is_binary(key) and is_list(list) -> true
      _ -> false
    end) and length(pairs) >= 2
  end
end
