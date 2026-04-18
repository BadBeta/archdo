defmodule Archdo.Rules.EventSourcing.ImmutableEvents do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "8.3"

  @impl true
  def description, do: "Events must be immutable structs"

  @impl true
  def analyze(file, ast, _opts) do
    case event_module?(ast) do
      false -> []
      true -> check_has_struct(file, ast) ++ check_no_mutation(file, ast)
    end
  end

  defp check_has_struct(file, ast) do
    has_struct? = AST.contains?(ast, fn
      {:defstruct, _, _} -> true
      # Macro-based event definitions (defevent, deftypedstruct, etc.)
      # generate a struct internally — common in Trento, Spear, etc.
      {:defevent, _, _} -> true
      {:typedstruct, _, _} -> true
      {:embedded_schema, _, _} -> true
      _ -> false
    end) or uses_event_macro?(ast)

    if has_struct? do
      []
    else
      module_name = AST.extract_module_name(ast)

      [
        Diagnostic.error("8.3",
          title: "Event without struct definition",
          message: "Event #{module_name} does not define a struct or use an event-builder macro",
          why:
            "Events are persisted facts that get serialized, replayed, and pattern-matched against. A plain " <>
              "module without a struct cannot be deserialized into a known shape, defeats compile-time field " <>
              "checks, and breaks every projector and process manager that pattern-matches the event.",
          alternatives: [
            Fix.new(
              summary: "Add `defstruct` with the event's payload fields",
              detail:
                "List every field the event carries. Pair it with `@derive Jason.Encoder` so the event store " <>
                  "can serialize it. Use `@enforce_keys` for fields that must always be present.",
              example: """
              ```elixir
              defmodule #{module_name} do
                @derive Jason.Encoder
                @enforce_keys [:account_id]
                defstruct [:account_id, :name, :occurred_at]
              end
              ```
              """,
              applies_when: "Always — events should always be explicit structs."
            ),
            Fix.new(
              summary: "Use the project's event-builder macro (`use MyApp.Event`, `defevent`, `typedstruct`, …)",
              detail:
                "Some codebases wrap defstruct in a macro that also derives Jason.Encoder, registers the event " <>
                  "type, and adds metadata. Use the same macro the rest of the events in this codebase use.",
              applies_when: "The codebase already standardizes on an event-builder macro."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#8.3"],
          context: %{module: module_name, kind: :missing_struct},
          file: file,
          line: 1
        )
      ]
    end
  end

  # Detect modules using a custom event-builder macro (e.g., use MyApp.Event)
  defp uses_event_macro?(ast) do
    AST.contains?(ast, fn
      {:use, _, [{:__aliases__, _, aliases} | _]} ->
        last =
          aliases
          |> List.last()
          |> Atom.to_string()
        last == "Event" or String.ends_with?(last, "Event")
      _ -> false
    end)
  end

  defp check_no_mutation(file, ast) do
    # Look for struct update syntax: %{event | field: value} outside upcasting
    AST.find_all(ast, fn
      {:%, _, [_, {:%{}, _, [{:|, _, _}]}]} -> true
      _ -> false
    end)
    |> Enum.map(fn {_, meta, _} ->
      Diagnostic.warning("8.3",
        title: "Event struct mutated after creation",
        message: "Event struct is updated via the `%{event | field: value}` syntax",
        why:
          "Events are historical facts and must be treated as immutable once emitted. Changing fields on a " <>
            "stored event corrupts the audit trail and breaks any projector or process manager that already " <>
            "consumed the original value.",
        alternatives: [
          Fix.new(
            summary: "Emit a new event instead of mutating the existing one",
            detail:
              "If the data needs to change, that change is itself a fact — model it as a new event " <>
                "(e.g. `EventCorrected`, `EventSuperseded`) and let projectors collapse the history.",
            applies_when: "The change reflects a new business decision."
          ),
          Fix.new(
            summary: "Use an event upcaster module for schema evolution",
            detail:
              "If the goal is to migrate stored events to a new shape on read, do it inside an upcaster (a " <>
                "module under an `Upcaster`/`Upcast` namespace). The rule whitelists those modules.",
            applies_when: "You are evolving the event schema, not changing business data."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#8.3"],
        context: %{kind: :mutation},
        file: file,
        line: AST.line(meta)
      )
    end)
  end

  defp event_module?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {:defmodule, _, [{:__aliases__, _, aliases} | _]} = node, _acc ->
          parts = Enum.map(aliases, &Atom.to_string/1)
          last = List.last(parts)

          # Must be *under* an Events/Event namespace (not the namespace itself).
          # And the module's own name shouldn't look like a utility/helper.
          in_events_ns = "Events" in parts or "Event" in parts
          is_namespace_root = last in ["Events", "Event"]
          is_utility = last in ["Util", "Utils", "Helper", "Helpers", "Support", "Builder"]

          is_upcaster =
            Enum.any?(parts, fn p ->
              String.contains?(String.downcase(p), "upcast")
            end)

          {node, in_events_ns and not is_namespace_root and not is_utility and not is_upcaster}

        node, acc ->
          {node, acc}
      end)

    found?
  end

end
