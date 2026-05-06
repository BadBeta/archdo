defmodule Archdo.Rules.OTP.GenServerCounterIncrementCall do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.69"

  @impl true
  def description,
    do:
      "GenServer `handle_call` that's just a counter increment — use `:counters` " <>
        "or `:atomics` to skip the message round-trip"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_counter_calls(file, ast)
    end
  end

  defp find_counter_calls(file, ast) do
    case AST.genserver_module?(ast) do
      false -> []
      true -> ast |> AST.find_all(&counter_handle_call?/1) |> Enum.map(&diagnose(file, &1))
    end
  end

  # `def handle_call(_, _, state), do: {:reply, _, <counter-update>}`
  defp counter_handle_call?({:def, _, [{:handle_call, _, _args}, [do: body]]}),
    do: counter_reply?(body)

  defp counter_handle_call?({:def, _, [{:handle_call, _, _args}, [{{:__block__, _, [:do]}, body}]]}),
    do: counter_reply?(body)

  defp counter_handle_call?(_), do: false

  defp counter_reply?({:{}, _, [:reply, _reply, new_state]}), do: counter_state?(new_state)
  defp counter_reply?({:reply, _reply, _new_state} = tup), do: counter_state?(elem(tup, 2))
  defp counter_reply?(_), do: false

  # `state + N` — bare counter
  defp counter_state?({:+, _, [{state, _, ctx}, n]})
       when is_atom(state) and (is_atom(ctx) or is_nil(ctx)) and is_integer(n),
       do: true

  # `%{state | field: state.field + 1}` — single-field counter increment
  defp counter_state?({:%{}, _, [{:|, _, [_state, [{_field, increment_expr}]]}]}),
    do: counter_increment_expr?(increment_expr)

  defp counter_state?(_), do: false

  defp counter_increment_expr?({:+, _, [{{:., _, [_var, _field]}, _, []}, n]})
       when is_integer(n),
       do: true

  defp counter_increment_expr?(_), do: false

  defp diagnose(file, {:def, meta, _}) do
    Diagnostic.info("5.69",
      title: "GenServer counter `handle_call` — use `:counters` / `:atomics`",
      message:
        "This `handle_call` does nothing but bump a counter. Every caller pays the " <>
          "GenServer message round-trip (encode the call, send to mailbox, " <>
          "schedule, run the callback, encode the reply). For a counter, that's " <>
          "100x more work than the actual increment.",
      why:
        "`:counters` (lock-free 64-bit signed integers) and `:atomics` (lock-free " <>
          "atomic integers, including `add_get`, `compare_exchange`) are designed " <>
          "for this. They live outside any process — every caller updates them " <>
          "without a message — and BEAM keeps them coherent across schedulers. " <>
          "A GenServer-wrapped counter is also a single-process bottleneck: " <>
          "thousands of writers serialize through one mailbox. `:counters` " <>
          "scales linearly with cores.",
      alternatives: [
        Fix.new(
          summary: "Replace with `:counters`",
          detail:
            "# Create the counter at app start (use :persistent_term to share):\n" <>
              "ref = :counters.new(1, [:write_concurrency])\n" <>
              ":persistent_term.put(MyApp.Stats, ref)\n\n" <>
              "# Increment from anywhere (no message):\n" <>
              "def hit, do: :counters.add(:persistent_term.get(MyApp.Stats), 1, 1)\n\n" <>
              "# Read:\n" <>
              "def value, do: :counters.get(:persistent_term.get(MyApp.Stats), 1)",
          applies_when:
            "When the GenServer's only state is one or more integer counters."
        ),
        Fix.new(
          summary: "Or use `:atomics` if you need compare-and-swap / wider arithmetic",
          detail:
            "ref = :atomics.new(1, signed: true)\n" <>
              ":atomics.add_get(ref, 1, 1)            # increment + read in one call\n" <>
              ":atomics.compare_exchange(ref, 1, expected, new)",
          applies_when: "When you need atomic CAS (e.g., bounded ring buffer indices)."
        )
      ],
      references: [
        "elixir-implementing/SKILL.md#9.2",
        "elixir-implementing/SKILL.md#10.5"
      ],
      context: %{},
      file: file,
      line: AST.line(meta)
    )
  end

  defp diagnose(_file, _node), do: []
end
