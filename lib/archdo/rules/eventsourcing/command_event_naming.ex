defmodule Archdo.Rules.EventSourcing.CommandEventNaming do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "8.1"

  @impl true
  def description, do: "Commands use imperative form, events use past tense"

  # Imperative-form prefixes that should NOT appear at the start of an event name
  @imperative_prefixes ~w(Create Update Delete Remove Add Set Register Cancel
    Approve Reject Assign Start Stop Send Submit Close Open Move Transfer
    Deposit Withdraw Activate Deactivate Enable Disable Grant Revoke Reset
    Change Mark Save Schedule Process Verify)

  # Past-tense suffixes that should NOT appear at the end of a command name
  @past_suffixes ~w(ed ied ten ade orn own elt rrowed)

  @impl true
  def analyze(file, ast, _opts) do
    case commanded_project?(ast) do
      false -> []
      true -> check_naming(file, ast)
    end
  end

  defp check_naming(file, ast) do
    {_, results} =
      Macro.prewalk(ast, [], fn
        {:defmodule, meta, [{:__aliases__, _, aliases} | _]} = node, acc ->
          module_name = AST.module_name(Module.concat(aliases))
          parts = String.split(module_name, ".")
          name = List.last(parts)

          cond do
            command_module?(parts) and looks_like_event_name?(name) ->
              {node, [command_diag(file, AST.line(meta), module_name, name) | acc]}

            event_module?(parts) and looks_like_command_name?(name) ->
              {node, [event_diag(file, AST.line(meta), module_name, name) | acc]}

            true ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(results)
  end

  defp command_diag(file, line, module_name, name) do
    Diagnostic.warning("8.1",
      title: "Command named in past tense",
      message: "Command module #{module_name} ends in a past-tense form (#{name})",
      why:
        "Event sourcing relies on the naming convention to distinguish intent from fact: commands express " <>
          "an instruction to do something (imperative), events record that something happened (past tense). " <>
          "A past-tense command name reads like an event and obscures whether the module describes a request or a historical fact.",
      alternatives: [
        Fix.new(
          summary: "Rename the module to imperative verb + noun",
          detail:
            "Pick the verb that describes the user-facing intent (e.g. `CreateAccount`, `DepositFunds`, " <>
              "`SubmitOrder`) and rename the module + file accordingly. Update the router and any references.",
          applies_when: "The module is genuinely a command (handled by an aggregate's execute/2)."
        ),
        Fix.new(
          summary: "Move the module under Events if it actually describes a fact",
          detail:
            "If the module is reporting that something already happened (and is consumed by event handlers " <>
              "or projectors), it belongs under the Events namespace, not Commands.",
          applies_when: "The module is actually an event that was misfiled under Commands."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#8.1"],
      context: %{module: module_name, kind: :command, name: name},
      file: file,
      line: line
    )
  end

  defp event_diag(file, line, module_name, name) do
    Diagnostic.warning("8.1",
      title: "Event named in imperative form",
      message: "Event module #{module_name} starts with an imperative verb (#{name})",
      why:
        "Events are historical facts and conventionally use past-tense names so handlers can read them as " <>
          "statements about what already happened. An imperative event name implies an action still to be " <>
          "taken and confuses the command/event split that the rest of the codebase relies on.",
      alternatives: [
        Fix.new(
          summary: "Rename the module to noun + past-tense verb",
          detail:
            "Restate the fact in past tense: `AccountCreated`, `FundsDeposited`, `OrderSubmitted`. Update the " <>
              "event store registration, handlers, projectors, and any pattern matches.",
          applies_when: "The module is genuinely an event (emitted by an aggregate's execute/2)."
        ),
        Fix.new(
          summary: "Move the module under Commands if it describes an intent",
          detail:
            "If the module is actually a request to do something (handled by an aggregate, not consumed by " <>
              "projectors), it belongs under Commands.",
          applies_when: "The module is actually a command misfiled under Events."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#8.1"],
      context: %{module: module_name, kind: :event, name: name},
      file: file,
      line: line
    )
  end

  defp command_module?(parts), do: "Commands" in parts or "Command" in parts
  defp event_module?(parts), do: "Events" in parts or "Event" in parts

  # An event name looks like a command if it starts with a known imperative verb
  # AND doesn't end with a past-tense suffix (to avoid false positives like CreatedAccount)
  defp looks_like_command_name?(name) do
    Enum.any?(@imperative_prefixes, &String.starts_with?(name, &1)) and
      not Enum.any?(@past_suffixes, &String.ends_with?(name, &1))
  end

  # A command name looks like an event if it ends with a clear past-tense suffix
  # AND doesn't START with an imperative verb (to avoid false positives like StartTed/Started)
  defp looks_like_event_name?(name) do
    Enum.any?(@past_suffixes, &String.ends_with?(name, &1)) and
      not Enum.any?(@imperative_prefixes, &String.starts_with?(name, &1))
  end

  defp commanded_project?(ast) do
    AST.contains?(ast, fn
      {:use, _, [{:__aliases__, _, aliases} | _]} ->
        mod = Module.concat(aliases)

        mod in [
          Commanded.Commands.Router,
          Commanded.Aggregates.Aggregate,
          Commanded.Event.Handler,
          Commanded.ProcessManagers.ProcessManager
        ]

      _ ->
        false
    end) or has_command_event_namespace?(ast)
  end

  defp has_command_event_namespace?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {:defmodule, _, [{:__aliases__, _, aliases} | _]} = node, _acc ->
          parts = Enum.map(aliases, &Atom.to_string/1)
          {node, "Commands" in parts or "Events" in parts}

        node, acc ->
          {node, acc}
      end)

    found?
  end
end
