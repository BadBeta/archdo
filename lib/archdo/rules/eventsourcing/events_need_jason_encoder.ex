defmodule Archdo.Rules.EventSourcing.EventsNeedJasonEncoder do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Rules.EventSourcing.Helpers

  @impl true
  def id, do: "8.5"

  @impl true
  def description, do: "Event structs must derive Jason.Encoder for serialization"

  @impl true
  def analyze(file, ast, _opts) do
    case event_module?(ast) and not Helpers.upcaster_module?(ast) do
      false -> []
      true -> check_jason_encoder(file, ast)
    end
  end

  defp check_jason_encoder(file, ast) do
    has_struct? =
      AST.contains?(ast, fn
        {:defstruct, _, _} -> true
        _ -> false
      end)

    has_derive_jason? =
      AST.contains?(ast, fn
        {:@, _, [{:derive, _, [{:__aliases__, _, [:Jason, :Encoder]}]}]} ->
          true

        # @derive [Jason.Encoder] list form
        {:@, _, [{:derive, _, [list]}]} when is_list(list) ->
          Enum.any?(list, fn
            {:__aliases__, _, [:Jason, :Encoder]} -> true
            _ -> false
          end)

        # @derive {Jason.Encoder, only: [...]}
        {:@, _, [{:derive, _, [{{:__aliases__, _, [:Jason, :Encoder]}, _}]}]} ->
          true

        _ ->
          false
      end)

    if has_struct? and not has_derive_jason? do
      module_name = AST.extract_module_name(ast)

      [
        Diagnostic.warning("8.5",
          title: "Event missing Jason.Encoder derivation",
          message: "Event #{module_name} defines a struct but does not `@derive Jason.Encoder`",
          why:
            "Event stores serialize events to JSON before persisting them. A struct without an encoder either " <>
              "raises at write time (Protocol.UndefinedError) or — worse — is silently encoded by a fallback " <>
              "that drops fields, producing events that cannot be replayed into the original shape.",
          alternatives: [
            Fix.new(
              summary: "Add `@derive Jason.Encoder` above `defstruct`",
              detail:
                "The simplest correct form. All public fields are serialized. Place the attribute on the line " <>
                  "directly before defstruct.",
              example: """
              ```elixir
              defmodule #{module_name} do
                @derive Jason.Encoder
                defstruct [:account_id, :name, :occurred_at]
              end
              ```
              """,
              applies_when: "Every field on the struct is safe to serialize."
            ),
            Fix.new(
              summary: "Use `@derive {Jason.Encoder, only: [...]}` to whitelist fields",
              detail:
                "If the struct contains internal or transient fields you do not want stored on the event, " <>
                  "list the persistable fields explicitly. Anything not in the list is dropped from the JSON.",
              applies_when: "The struct has fields that should not be persisted."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#8.5"],
          context: %{module: module_name},
          file: file,
          line: 1
        )
      ]
    else
      []
    end
  end

  defp event_module?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {:defmodule, _, [{:__aliases__, _, aliases} | _]} = node, _acc ->
          parts = Enum.map(aliases, &Atom.to_string/1)
          last = List.last(parts)

          in_events_ns = "Events" in parts or "Event" in parts
          is_namespace_root = last in ["Events", "Event"]
          is_utility = last in ["Util", "Utils", "Helper", "Helpers", "Support", "Builder"]

          {node, in_events_ns and not is_namespace_root and not is_utility}

        node, acc ->
          {node, acc}
      end)

    found?
  end
end
