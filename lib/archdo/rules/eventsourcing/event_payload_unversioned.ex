defmodule Archdo.Rules.EventSourcing.EventPayloadUnversioned do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "8.9"

  @impl true
  def description,
    do: "Event/command struct missing :version / :schema_version / @version — breaks replay"

  @version_field_names [:version, :schema_version, :event_version]

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_unversioned_payload(file, ast)
    end
  end

  defp find_unversioned_payload(file, ast) do
    {_, hits} =
      Macro.prewalk(ast, [], fn
        {:defmodule, meta, [{:__aliases__, _, aliases}, [do: body]]} = node, acc ->
          {node, classify_module(aliases, meta, body, file, acc)}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(hits)
  end

  # §§ elixir-implementing: §5.2 — multi-clause head dispatch over the
  # event-or-command predicate.
  defp classify_module(aliases, meta, body, file, acc) do
    case event_or_command_module?(aliases) do
      false -> acc
      kind -> maybe_flag_module(kind, meta, body, aliases, file, acc)
    end
  end

  defp maybe_flag_module(kind, meta, body, aliases, file, acc) do
    case versioned?(body) do
      true -> acc
      false -> [build_diagnostic(file, meta, kind, aliases) | acc]
    end
  end

  # §§ elixir-planning: §6.5 — boundary detection by namespace. Following the
  # convention used by 8.1 command_event_naming: an "Events" or "Commands"
  # path segment marks the module as part of the event-sourcing surface.
  defp event_or_command_module?(aliases) do
    parts = Enum.map(aliases, &Atom.to_string/1)

    cond do
      "Events" in parts or "Event" in parts -> :event
      "Commands" in parts or "Command" in parts -> :command
      true -> false
    end
  end

  # A module is versioned if EITHER:
  #   - it has a defstruct with a :version-family field, OR
  #   - it has a @version (or @schema_version) module attribute
  defp versioned?(body) do
    body_list = unwrap_block(body)
    has_version_field?(body_list) or has_version_attribute?(body_list)
  end

  defp unwrap_block({:__block__, _, items}) when is_list(items), do: items
  defp unwrap_block(single), do: [single]

  defp has_version_field?(body_list) do
    Enum.any?(body_list, fn
      {:defstruct, _, [fields]} when is_list(fields) ->
        Enum.any?(fields, &version_field?/1)

      _ ->
        false
    end)
  end

  defp version_field?({name, _default}), do: name in @version_field_names
  defp version_field?(name) when is_atom(name), do: name in @version_field_names
  defp version_field?(_), do: false

  defp has_version_attribute?(body_list) do
    Enum.any?(body_list, fn
      {:@, _, [{name, _, [_value]}]} when is_atom(name) ->
        name in [:version, :schema_version, :event_version]

      _ ->
        false
    end)
  end

  defp build_diagnostic(file, meta, kind, aliases) do
    module_name = Enum.map_join(aliases, ".", &Atom.to_string/1)
    label = if kind == :event, do: "Event", else: "Command"

    Diagnostic.warning("8.9",
      title: "#{label} struct missing version",
      message:
        "#{module_name} has no `:version` field, no `@version` attribute, and no " <>
          "alternative version marker — historical instances of this #{label} cannot " <>
          "be safely upcasted across schema changes.",
      why:
        "Event-sourced systems must be able to read and replay older instances of an " <>
          "event after the schema evolves. Without a version marker, an upcaster has " <>
          "no way to dispatch on \"which version of OrderPlaced is this?\" — adding a " <>
          "field becomes a breaking change against the event store. Same concern for " <>
          "commands flowing through a versioned API.",
      alternatives: [
        Fix.new(
          summary: "Add a :version field to the struct with a compile-time default",
          detail:
            "Add `@version 1` and put `version: @version` in the defstruct field list. " <>
              "When the schema evolves, bump @version in a new module and write an " <>
              "upcaster that dispatches on the version value.",
          applies_when: "The event/command is persisted or sent across a versioned wire."
        ),
        Fix.new(
          summary: "Use :schema_version if the codebase already established that name",
          detail:
            "If other events in the project use :schema_version or :event_version, " <>
              "match the convention. The rule accepts any of: :version, :schema_version, " <>
              ":event_version.",
          applies_when: "The project has an existing version-field naming convention."
        )
      ],
      tags: [:contract, :event_sourcing],
      file: file,
      line: AST.line(meta)
    )
  end
end
