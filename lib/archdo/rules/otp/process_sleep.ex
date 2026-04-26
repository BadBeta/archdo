defmodule Archdo.Rules.OTP.ProcessSleep do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.30"

  @impl true
  def description, do: "No Process.sleep in production code"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) or script_file?(file) do
      []
    else
      find_process_sleep(file, ast) ++ find_timer_sleep(file, ast)
    end
  end

  defp find_process_sleep(file, ast) do
    Enum.map(
      AST.find_all(ast, fn
        {{:., _, [{:__aliases__, _, [:Process]}, :sleep]}, _meta, _args} -> true
        _ -> false
      end),
      fn {_, meta, _} ->
        sleep_diag(file, meta, "Process.sleep/1")
      end
    )
  end

  defp find_timer_sleep(file, ast) do
    Enum.map(
      AST.find_all(ast, fn
        {{:., _, [:timer, :sleep]}, _meta, _args} -> true
        _ -> false
      end),
      fn {_, meta, _} ->
        sleep_diag(file, meta, ":timer.sleep/1")
      end
    )
  end

  defp sleep_diag(file, meta, call) do
    Diagnostic.info("5.30",
      title: "Sleep in production code",
      message: "#{call} blocks the calling process inside production (non-test, non-script) code",
      why:
        "Sleep blocks the entire process: a GenServer can't process any other messages, a Task wastes a " <>
          "scheduler thread, and a request handler holds open a connection while doing nothing. For retry " <>
          "logic it prevents the process from handling other work during the wait. Sleeping is almost never " <>
          "the right answer in OTP code.",
      alternatives: [
        Fix.new(
          summary: "Use `Process.send_after/3` to schedule the next step asynchronously",
          detail:
            "Schedule a self-message after the delay (`Process.send_after(self(), :retry, 1_000)`) and handle " <>
              "it in `handle_info/2`. The process is free to handle other messages in the meantime, and the " <>
              "retry still fires at the scheduled time.",
          example: """
          ```elixir
          def handle_info({:retry, attempt}, state) do
            case do_thing() do
              {:error, _} when attempt < 3 ->
                Process.send_after(self(), {:retry, attempt + 1}, 1_000 * attempt)
                {:noreply, state}

              result ->
                {:noreply, handle_result(state, result)}
            end
          end
          ```
          """,
          applies_when: "You need a delayed action or backoff."
        ),
        Fix.new(
          summary: "Use `:timer.send_interval/2` for periodic work",
          detail:
            "If you wanted a simple polling loop, send an interval message from init/1 and handle it like " <>
              "any other message. The work happens on the schedule but the process never blocks.",
          applies_when: "You want a periodic timer."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#5.30"],
      context: %{call: call},
      file: file,
      line: AST.line(meta)
    )
  end

  defp script_file?(file), do: String.ends_with?(file, ".exs")
end
