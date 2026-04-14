defmodule Archdo.Rules.OTP.TimeoutAsPolling do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.15"

  @impl true
  def description, do: "GenServer timeout misuse as polling mechanism"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.genserver_module?(ast) do
      false ->
        []
      true ->
      callbacks = AST.extract_callbacks(ast)

      # Find handle_info clauses that match :timeout
      timeout_handlers =
        (callbacks[:handle_info] || [])
        |> Enum.filter(&timeout_handler?/1)

      # Only flag if the timeout handler itself returns a timeout
      # (indicating it's being used as a recurring timer)
      timeout_handlers
      |> Enum.filter(&returns_timeout?/1)
      |> Enum.map(fn {meta, _args, _body} ->
        Diagnostic.warning("5.15",
          title: "GenServer timeout used as periodic timer",
          message: "handle_info(:timeout, ...) returns a new timeout, treating it as a recurring timer",
          why:
            "GenServer's `:timeout` value is reset by every incoming message. If any other message arrives " <>
              "within the timeout window — a cast, a call, an :EXIT — the :timeout never fires, and the " <>
              "periodic work silently stops happening. The bug is invisible until you notice the work isn't " <>
              "running, often weeks later in production.",
          alternatives: [
            Fix.new(
              summary: "Use `:timer.send_interval/2` for fixed-interval periodic work",
              detail:
                "From init/1, call `:timer.send_interval(5_000, :tick)` and add a `handle_info(:tick, state)` " <>
                  "clause. The interval is independent of the GenServer's normal message flow and fires reliably.",
              example: """
              ```elixir
              def init(_) do
                :timer.send_interval(5_000, :tick)
                {:ok, %{}}
              end

              def handle_info(:tick, state) do
                # ... work ...
                {:noreply, state}
              end
              ```
              """,
              applies_when: "You want a fixed-interval periodic timer."
            ),
            Fix.new(
              summary: "Use `Process.send_after/3` and re-schedule explicitly each tick",
              detail:
                "Schedule the next tick at the end of every handler invocation: " <>
                  "`Process.send_after(self(), :tick, 5_000)`. This gives you fine-grained control over the " <>
                  "interval (e.g. exponential backoff) and is independent of incoming messages.",
              applies_when: "You need adaptive timing or backoff between ticks."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#5.15"],
          context: %{},
          file: file,
          line: AST.line(meta)
        )
      end)
    end
  end

  defp timeout_handler?({_meta, args, _body}) do
    case args do
      [{:__block__, _, [:timeout]} | _] -> true
      [:timeout | _] -> true
      _ -> false
    end
  end

  defp returns_timeout?({_meta, _args, body}) do
    AST.contains?(body, fn
      # {:noreply, state, timeout_value} — tuple with 3 elements where last is numeric
      {:{}, _, [:noreply, _, timeout]} when is_integer(timeout) -> true
      {:{}, _, [:reply, _, _, timeout]} when is_integer(timeout) -> true
      _ -> false
    end)
  end
end
