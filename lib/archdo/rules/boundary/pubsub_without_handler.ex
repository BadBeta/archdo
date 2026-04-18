defmodule Archdo.Rules.Boundary.PubsubWithoutHandler do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "1.17"

  @impl true
  def description, do: "LiveView subscribes to PubSub but has no handle_info for broadcasts"

  @impl true
  def analyze(file, ast, _opts) do
    cond do
      AST.test_file?(file) -> []
      live_view_file?(file) or uses_live_view?(ast) -> check_pubsub(file, ast)
      true -> []
    end
  end

  defp check_pubsub(file, ast) do
    subscribes =
      AST.contains?(ast, fn
        {{:., _, [{:__aliases__, _, _}, :subscribe]}, _, _} -> true
        {{:., _, [_, :subscribe]}, _, _} -> true
        _ -> false
      end)

    has_handle_info =
      AST.contains?(ast, fn
        {:def, _, [{:handle_info, _, _} | _]} -> true
        _ -> false
      end)

    has_attach_hook =
      AST.contains?(ast, fn
        {:attach_hook, _, _} -> true
        _ -> false
      end)

    if subscribes and not has_handle_info and not has_attach_hook do
      module_name = AST.extract_module_name(ast)

      [
        Diagnostic.warning("1.17",
          title: "PubSub subscribe without handler",
          message: "#{module_name} subscribes to PubSub but has no handle_info/2 to receive broadcasts",
          why:
            "PubSub.subscribe sets up a subscription, but broadcasts arrive as regular messages. " <>
              "Without handle_info/2, the messages pile up in the LiveView process mailbox — " <>
              "consuming memory and never being processed. The subscription is effectively dead.",
          alternatives: [
            Fix.new(
              summary: "Add handle_info/2 to process broadcasts",
              detail:
                "```elixir\n" <>
                  "def handle_info(%Phoenix.Socket.Broadcast{event: event, payload: payload}, socket) do\n" <>
                  "  {:noreply, update_from_broadcast(socket, event, payload)}\n" <>
                  "end\n" <>
                  "```",
              applies_when: "The LiveView should react to broadcasts."
            ),
            Fix.new(
              summary: "Use attach_hook in on_mount for zero-boilerplate handling",
              detail:
                "Attach a :handle_info hook in on_mount that intercepts broadcast messages. " <>
                  "The LiveView itself needs no handle_info clause.",
              applies_when: "Using a shared subscriber module pattern."
            ),
            Fix.new(
              summary: "Remove the subscription if broadcasts aren't needed",
              detail:
                "If the subscribe was added but never wired up, remove it to avoid the " <>
                  "silent mailbox leak.",
              applies_when: "The subscription is dead code."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#1.17"],
          context: %{module: module_name},
          file: file,
          line: 1
        )
      ]
    else
      []
    end
  end

  defp live_view_file?(file) do
    String.contains?(file, "_live.ex") or
      String.contains?(file, "/live/")
  end

  defp uses_live_view?(ast) do
    AST.contains?(ast, fn
      {:use, _, [{:__aliases__, _, aliases} | _]} ->
        List.last(aliases) == :LiveView

      _ ->
        false
    end)
  end
end
