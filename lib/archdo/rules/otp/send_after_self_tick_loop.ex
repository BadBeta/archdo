defmodule Archdo.Rules.OTP.SendAfterSelfTickLoop do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.70"

  @impl true
  def description,
    do:
      "GenServer self-tick loop: `handle_info(:tick, _)` re-arms via " <>
        "`Process.send_after(self(), :tick, T)` with a constant T — could be " <>
        "`:timer.send_interval(T, self(), :tick)`"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_loops(file, ast)
    end
  end

  defp find_loops(file, ast) do
    case AST.genserver_module?(ast) do
      false -> []
      true -> diagnose_module(file, ast)
    end
  end

  # Module-level pattern: ANY `def handle_info(<msg>, _)` paired with
  # ANY `Process.send_after(self(), <same-msg>, <constant>)` somewhere
  # in the same module — even via a helper like `defp schedule_poll`.
  defp diagnose_module(file, ast) do
    handle_info_msgs = collect_handle_info_msgs(ast)
    rearms = collect_rearm_targets(ast)

    handle_info_msgs
    |> Enum.flat_map(fn {msg, meta} ->
      case Enum.any?(rearms, fn r -> ast_equiv?(r, msg) end) do
        true -> [diagnose(file, {:def, meta, []})]
        false -> []
      end
    end)
    |> Enum.uniq()
  end

  defp collect_handle_info_msgs(ast) do
    AST.find_all(ast, fn
      {:def, _, [{:handle_info, _, [_msg | _]}, _]} -> true
      _ -> false
    end)
    |> Enum.map(fn {:def, meta, [{:handle_info, _, [msg | _]}, _]} -> {msg, meta} end)
  end

  defp collect_rearm_targets(ast) do
    AST.find_all(ast, fn
      {{:., _, [{:__aliases__, _, [:Process]}, :send_after]}, _,
       [{:self, _, _}, _msg, delay]} ->
        constant_delay?(delay)

      _ ->
        false
    end)
    |> Enum.map(fn {{:., _, _}, _, [_, msg, _]} -> msg end)
  end

  # Constant-cadence delay: integer literal or `@module_attribute`.
  # Excludes per-call computed values (variables, arithmetic on state).
  defp constant_delay?({:__block__, _, [d]}), do: constant_delay?(d)
  defp constant_delay?(d) when is_integer(d), do: true
  defp constant_delay?({:@, _, [{name, _, ctx}]}) when is_atom(name) and is_atom(ctx),
    do: true

  defp constant_delay?({:@, _, [{name, _, nil}]}) when is_atom(name), do: true
  defp constant_delay?(_), do: false

  # Loose equivalence — atom vs atom, identical literals. Unwraps the
  # `literal_encoder` wrapper `{:__block__, _, [val]}` that production
  # parsing puts around literal atoms / numbers / strings.
  defp ast_equiv?(a, b), do: unwrap_literal(a) == unwrap_literal(b)

  defp unwrap_literal({:__block__, _, [val]}), do: val
  defp unwrap_literal(other), do: other

  defp diagnose(file, {:def, meta, _}) do
    Diagnostic.info("5.70",
      title: "Self-tick `handle_info` loop — consider `:timer.send_interval/3`",
      message:
        "This `handle_info` re-arms a tick by calling `Process.send_after(self(), " <>
          "<msg>, <constant>)` with the same message and a constant delay. The " <>
          "rearm-yourself idiom drifts (each iteration measures from when the " <>
          "previous `handle_info` ran, not from a fixed schedule). For a " <>
          "constant-cadence tick, `:timer.send_interval/3` is simpler and " <>
          "non-drifting.",
      why:
        "`:timer.send_interval(T, self(), :tick)` schedules a recurring message " <>
          "from the BEAM's `:timer` server at fixed intervals. The send_after- " <>
          "rearm idiom is only the right choice when you need: (a) variable delay " <>
          "between ticks (backoff, jitter), (b) cancellation by reference, or (c) " <>
          "a one-shot `:tick` followed by a state change. If none of those apply, " <>
          "send_interval reads better. Note: send_interval is fine for short, " <>
          "consistent intervals; for long intervals or persistent scheduling, " <>
          "Oban.Cron is the better choice.",
      alternatives: [
        Fix.new(
          summary: "Replace with `:timer.send_interval/3`",
          detail:
            "def init(_) do\n" <>
              "  {:ok, ref} = :timer.send_interval(1_000, self(), :tick)\n" <>
              "  {:ok, %{tick_ref: ref}}\nend\n\n" <>
              "def handle_info(:tick, state) do\n" <>
              "  do_work()\n" <>
              "  {:noreply, state}     # No rearm — :timer keeps sending.\n" <>
              "end\n\n" <>
              "# Cancel on terminate if needed:\n" <>
              "def terminate(_, %{tick_ref: ref}), do: :timer.cancel(ref)",
          applies_when: "When the cadence is constant for the GenServer's lifetime."
        ),
        Fix.new(
          summary: "Or keep `send_after` if cadence varies (backoff, jitter)",
          detail:
            "If each tick's delay differs (exponential backoff, randomized jitter, " <>
              "scheduled work that should pause when the queue is full), keep " <>
              "send_after. Document the variability in the moduledoc so future " <>
              "readers don't \"simplify\" to send_interval and break the design.",
          applies_when: "When the delay is dynamic, not constant."
        )
      ],
      references: ["elixir-implementing/SKILL.md#9.2"],
      context: %{},
      file: file,
      line: AST.line(meta)
    )
  end

  defp diagnose(_file, _node), do: []
end
