defmodule Archdo.Rules.StateMachine.UndeclaredNextState do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — SM-A. A `{:next_state, X, ...}` return
  # whose target X is not in the module's `@states [...]` declaration.
  # Guaranteed runtime crash — the state machine receives an event it
  # has no callback for. Pattern-matching makes this invisible at
  # compile time. Rule is opt-in: only fires on modules that declare
  # `@states`.

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Rules.StateMachine.Helpers

  @impl true
  def id, do: "SM-A"

  @impl true
  def description,
    do: "Transition target state not in module's declared @states set"

  @impl true
  def analyze(file, ast, _opts) do
    case Helpers.declared_states(ast) do
      nil -> []
      states -> find_undeclared_targets(file, ast, states)
    end
  end

  defp find_undeclared_targets(file, ast, states) do
    {_, found} =
      Macro.prewalk(ast, [], fn node, acc ->
        case extract_next_state(node) do
          nil -> {node, acc}
          {target, line} ->
            case MapSet.member?(states, target) do
              true -> {node, acc}
              false -> {node, [{target, line} | acc]}
            end
        end
      end)

    found
    |> Enum.reverse()
    |> Enum.map(fn {target, line} -> build_diagnostic(file, line, target, states) end)
  end

  # `{:next_state, :foo, _}` parses (with literal_encoder) as
  # `{:{}, _meta, [{:__block__, _, [:next_state]}, {:__block__, _, [:foo]}, _data]}`.
  # Bare 3+-tuples are always wrapped as `{:{}, _, args}`. 2-tuples are
  # not wrapped this way but `{:next_state, _, _}` is at minimum 3 elements.
  defp extract_next_state(
         {:{}, meta, [{:__block__, _, [:next_state]}, {:__block__, _, [target]} | _]}
       )
       when is_atom(target) do
    {target, AST.line(meta)}
  end

  # Without literal_encoder (test fixtures sometimes), the same parses as
  # `{:{}, _, [:next_state, :foo, _]}`.
  defp extract_next_state({:{}, meta, [:next_state, target | _]}) when is_atom(target) do
    {target, AST.line(meta)}
  end

  defp extract_next_state(_), do: nil

  defp build_diagnostic(file, line, target, states) do
    Diagnostic.warning("SM-A",
      title: "Transition target state not in @states",
      message:
        "Transition `{:next_state, #{inspect(target)}, ...}` targets a state not " <>
          "declared in @states (allowed: #{inspect(MapSet.to_list(states))})",
      why:
        "An undeclared `:next_state` target is a guaranteed runtime crash — the " <>
          "state machine will receive an event it has no callback for. " <>
          "Pattern-matching makes this invisible at compile time in handle-event-" <>
          "function mode and in hand-rolled machines.",
      alternatives: [
        Fix.new(
          summary: "Correct the target state",
          detail: "Often a typo: #{inspect(target)} → an atom from @states.",
          applies_when: "The transition meant a declared state."
        ),
        Fix.new(
          summary: "Declare the new state",
          detail: "If #{inspect(target)} is a legitimate new state, add it to @states.",
          applies_when: "The state machine is gaining a new state."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#SM-A"],
      context: %{target: target, declared: MapSet.to_list(states)},
      file: file,
      line: line
    )
  end
end
