defmodule Archdo.Rules.StateMachine.IncompleteStateMatch do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — SM-F. A `case state do :a -> ...; :b ->
  # ... end` (or equivalent) that's missing declared states without a
  # catch-all clause. The dual of SM-D: the spec declares states the
  # code doesn't handle, leading to CaseClauseError when the state
  # value is set legitimately but the consumer code is incomplete.
  # Rule is opt-in via `@states` declaration.

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Rules.StateMachine.Helpers

  @impl true
  def id, do: "SM-F"

  @impl true
  def description,
    do: "case-on-state misses declared states without a catch-all clause"

  @impl true
  def analyze(file, ast, _opts) do
    case Helpers.declared_states(ast) do
      nil -> []
      states -> find_incomplete_matches(file, ast, states)
    end
  end

  defp find_incomplete_matches(file, ast, states) do
    {_, found} =
      Macro.prewalk(ast, [], fn node, acc ->
        case extract_state_case(node) do
          nil -> {node, acc}
          {meta, matched_atoms, has_catch_all} -> {node, [{meta, matched_atoms, has_catch_all} | acc]}
        end
      end)

    found
    |> Enum.reverse()
    |> Enum.flat_map(fn {meta, matched, has_catch_all} ->
      missing = MapSet.difference(states, matched)

      cond do
        has_catch_all -> []
        MapSet.size(missing) == 0 -> []
        true -> [build_diagnostic(file, AST.line(meta), missing, states)]
      end
    end)
  end

  # `case state do ... end` where the discriminator is the bare
  # variable `state`. With literal_encoder the clause-list parses
  # as `[do: [{:->, _, [[pattern], body]}, ...]]`. The discriminator
  # appears as `{:state, _, _}` (variable reference).
  defp extract_state_case({:case, meta, [{:state, _, _}, [{:do, clauses}]]}) when is_list(clauses) do
    extract_clause_summary(meta, clauses)
  end

  defp extract_state_case(
         {:case, meta, [{:state, _, _}, [{{:__block__, _, [:do]}, clauses}]]}
       )
       when is_list(clauses) do
    extract_clause_summary(meta, clauses)
  end

  defp extract_state_case(_), do: nil

  defp extract_clause_summary(meta, clauses) do
    {atoms, has_catch_all} =
      Enum.reduce(clauses, {MapSet.new(), false}, fn
        {:->, _, [[{:_, _, _}], _]}, {set, _} -> {set, true}
        {:->, _, [[{:__block__, _, [:_]}], _]}, {set, _} -> {set, true}
        {:->, _, [[{var, _, ctx}], _]}, {set, _} when is_atom(var) and is_atom(ctx) ->
          # Bare variable pattern (`state -> ...`) — also a catch-all.
          {set, true}

        {:->, _, [[{:__block__, _, [atom]}], _]}, {set, ca} when is_atom(atom) ->
          {MapSet.put(set, atom), ca}

        {:->, _, [[atom], _]}, {set, ca} when is_atom(atom) ->
          {MapSet.put(set, atom), ca}

        _, acc ->
          acc
      end)

    {meta, atoms, has_catch_all}
  end

  defp build_diagnostic(file, line, missing, states) do
    Diagnostic.warning("SM-F",
      title: "Incomplete state match — declared states not handled",
      message:
        "case-on-state is missing #{inspect(MapSet.to_list(missing))} " <>
          "(declared in @states: #{inspect(MapSet.to_list(states))})",
      why:
        "The state declaration says these states exist but this case doesn't " <>
          "handle them. CaseClauseError fires the next time the state value is " <>
          "set legitimately and reaches this consumer.",
      alternatives: [
        Fix.new(
          summary: "Add the missing clauses",
          detail:
            "Handle each declared state explicitly, or add a `_ -> ...` catch-all " <>
              "with documented intent.",
          applies_when: "All declared states are reachable."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#SM-F"],
      context: %{missing: MapSet.to_list(missing), declared: MapSet.to_list(states)},
      file: file,
      line: line
    )
  end
end
