defmodule Archdo.Rules.OTP.MissingHandleInfo do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.37"

  @impl true
  def description, do: "GenServer without handle_info — unexpected messages pile up in mailbox"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      case AST.genserver_module?(ast) do
        false -> []
        true -> check_handle_info(file, ast)
      end
    end
  end

  defp check_handle_info(file, ast) do
    has_handle_info =
      AST.contains?(ast, fn
        {:def, _, [{:handle_info, _, _} | _]} -> true
        _ -> false
      end)

    # gen_statem uses handle_event, not handle_info
    is_statem =
      AST.contains?(ast, fn
        {:@, _, [{:behaviour, _, [{:__block__, _, [:gen_statem]}]}]} -> true
        {:@, _, [{:behaviour, _, [:gen_statem]}]} -> true
        _ -> false
      end)

    if not has_handle_info and not is_statem do
      module_name = AST.extract_module_name(ast)

      [
        Diagnostic.info("5.37",
          title: "GenServer without handle_info",
          message: "#{module_name} uses GenServer but defines no handle_info/2 clauses",
          why:
            "Any message sent to a GenServer that isn't a call or cast arrives via handle_info/2. " <>
              "Without it, these messages accumulate in the mailbox: monitor :DOWN messages, " <>
              "timer messages from Process.send_after, TCP/UDP socket data, and stray messages " <>
              "from linked processes. The mailbox grows silently until the process is killed by OOM.",
          alternatives: [
            Fix.new(
              summary: "Add a catch-all handle_info that logs unexpected messages",
              detail:
                "```elixir\n" <>
                  "@impl true\n" <>
                  "def handle_info(msg, state) do\n" <>
                  "  Logger.warning(\"Unexpected message in \#{__MODULE__}: \#{inspect(msg)}\")\n" <>
                  "  {:noreply, state}\n" <>
                  "end\n" <>
                  "```",
              applies_when: "The GenServer should not receive messages but might due to monitors or timers."
            ),
            Fix.new(
              summary: "Implement specific handle_info clauses for expected messages",
              detail:
                "If the GenServer uses Process.send_after, monitors, or subscribes to PubSub, " <>
                  "add explicit handle_info clauses for those message types.",
              applies_when: "The GenServer is expected to receive specific message types."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#5.37"],
          context: %{module: module_name},
          file: file,
          line: 1
        )
      ]
    else
      []
    end
  end
end
