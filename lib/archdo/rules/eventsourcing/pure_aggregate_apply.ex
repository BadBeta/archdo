defmodule Archdo.Rules.EventSourcing.PureAggregateApply do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "8.2"

  @impl true
  def description, do: "Aggregate apply/2 must be pure — no side effects"

  @side_effect_patterns [
    {[:GenServer], [:call, :cast]},
    {[:IO], [:puts, :write, :inspect]},
    {[:Logger], [:info, :warning, :error, :debug]},
    {[:File], nil},
    {[:Process], [:send]},
    {[:Repo], nil}
  ]

  @impl true
  def analyze(file, ast, _opts) do
    case aggregate_module?(ast) do
      false -> []
      true -> find_impure_apply(file, ast)
    end
  end

  defp find_impure_apply(file, ast) do
    module_name = AST.extract_module_name(ast)
    fns = AST.extract_functions(ast, :public)

    fns
    |> Enum.filter(fn {name, arity, _, _, _} -> name == :apply and arity == 2 end)
    |> Enum.flat_map(fn {_, _, _meta, _, body} ->
      side_effects = find_side_effects(body)

      Enum.map(side_effects, fn {desc, line} ->
        build_diagnostic(file, line, module_name, desc)
      end)
    end)
  end

  defp build_diagnostic(file, line, module_name, side_effect) do
    Diagnostic.error("8.2",
      title: "Side effect in aggregate apply/2",
      message: "#{module_name}.apply/2 calls #{side_effect} inside an event handler clause",
      why:
        "apply/2 is invoked on every event during aggregate rehydration, not just when the event is first emitted. " <>
          "Side effects there fire N times per process restart, spam observability tooling, and can re-trigger external systems " <>
          "(emails, webhooks, alerts) on every replay.",
      alternatives: [
        Fix.new(
          summary: "Move the side effect to the command handler (execute/2)",
          detail:
            "execute/2 runs exactly once per command, before any event is persisted. Emit the log or external call there. " <>
              "apply/2 should be a pure function from (state, event) to new state.",
          example: """
          ```elixir
          # apply/2 stays pure — only updates state
          def apply(error, %ErrorAlerted{} = ev) do
            %Error{error | frequency: error.frequency + 1, status: :alerted}
          end

          # execute/2 emits both the event and the side effect
          def execute(%Error{} = state, %AlertError{} = cmd) do
            Logger.error("\#{cmd.source} exceeded threshold")
            %ErrorAlerted{source: cmd.source}
          end
          ```
          """,
          applies_when: "The side effect should fire when the command is processed, not on replay."
        ),
        Fix.new(
          summary: "Move the side effect to a process manager subscribed to the event",
          detail:
            "Process managers react to persisted events asynchronously. They run once per emitted event " <>
              "(not once per replay) and are the right place for cross-aggregate workflows or external system calls.",
          applies_when:
            "The side effect needs to coordinate with other aggregates or external systems."
        )
      ],
      references: [
        "ARCHITECTURE_RULES.md#8.2",
        "https://hexdocs.pm/commanded/Commanded.Aggregate.html"
      ],
      context: %{
        module: module_name,
        function: "apply/2",
        side_effect: side_effect,
        line: line
      },
      file: file,
      line: line
    )
  end

  defp find_side_effects(nil), do: []

  defp find_side_effects(body) do
    # Check for known side-effect calls
    module_calls =
      AST.find_all(body, fn
        {{:., _, [{:__aliases__, _, mod_parts}, func]}, _, _} ->
          Enum.any?(@side_effect_patterns, fn
            {mod, nil} -> List.last(mod_parts) in mod
            {mod, funcs} -> mod_parts == mod and func in funcs
          end)
        _ -> false
      end)
      |> Enum.map(fn {{:., _, [{:__aliases__, _, mod_parts}, func]}, meta, _} ->
        {"#{Enum.join(mod_parts, ".")}.#{func}", AST.line(meta)}
      end)

    # Check for send/2
    sends =
      AST.find_all(body, fn
        {:send, _, [_, _]} -> true
        _ -> false
      end)
      |> Enum.map(fn {_, meta, _} -> {"send/2", AST.line(meta)} end)

    module_calls ++ sends
  end

  defp aggregate_module?(ast) do
    AST.contains?(ast, fn
      {:use, _, [{:__aliases__, _, aliases} | _]} ->
        mod = Module.concat(aliases)
        mod == Commanded.Aggregates.Aggregate
      _ -> false
    end) or has_execute_and_apply?(ast)
  end

  defp has_execute_and_apply?(ast),
    do: Archdo.Rules.EventSourcing.Helpers.aggregate_shape?(ast)
end
