defmodule Archdo.Rules.Module.SystemTimeForDuration do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.89"

  @impl true
  def description,
    do:
      "Function body has 2+ `System.system_time/0,1` calls — likely measuring " <>
        "duration; use `System.monotonic_time/1` (NTP-immune)"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_pairs(file, ast)
    end
  end

  defp find_pairs(file, ast) do
    ast
    |> AST.extract_functions(:all)
    |> Enum.flat_map(fn {_name, _arity, _meta, _args, body} ->
      maybe_diagnose_body(file, body)
    end)
  end

  defp maybe_diagnose_body(file, body) do
    case system_time_calls(body) do
      [first, _ | _] -> maybe_diagnose_with_subtraction(file, body, first)
      _ -> []
    end
  end

  defp maybe_diagnose_with_subtraction(file, body, first) do
    case has_subtraction?(body) do
      true -> [build_diagnostic(file, AST.line(elem(first, 1)))]
      false -> []
    end
  end

  defp system_time_calls(body) do
    AST.find_all(body, &system_time_call?/1)
  end

  defp system_time_call?({{:., _, [{:__aliases__, _, [:System]}, :system_time]}, _, _}),
    do: true

  defp system_time_call?(_), do: false

  # Duration-measurement pattern: `t1 - t0` between two values that came
  # from the system_time calls. We don't trace the binding chain; we
  # just require ANY `-` arithmetic in the body. JWT iat/exp use `+ N`,
  # not `-`, so this discriminates well.
  defp has_subtraction?(body) do
    AST.contains?(body, fn
      {:-, _, [_, _]} -> true
      _ -> false
    end)
  end

  defp build_diagnostic(file, line) do
    Diagnostic.warning("6.89",
      title: "Two `System.system_time` calls — use `System.monotonic_time/1`",
      message:
        "This function calls `System.system_time/0,1` twice — almost always a " <>
          "duration measurement. `System.system_time` is wall-clock time and is " <>
          "subject to NTP adjustments, leap seconds, and manual operator changes; " <>
          "any of those can make `t1 - t0` negative or wildly off. Use " <>
          "`System.monotonic_time/1` for elapsed time.",
      why:
        "`monotonic_time` is guaranteed to be monotonically non-decreasing within a " <>
          "VM lifetime — the BEAM provides this regardless of what the system clock " <>
          "does. Telemetry, benchmarks, timeouts, retry backoffs, and rate-limit " <>
          "windows all need monotonic. `system_time` is for emitting absolute " <>
          "timestamps to logs / databases / external systems where you want the " <>
          "wall-clock value (and accept that it can move backwards). Mixing the " <>
          "two is a source of subtle bugs that only surface during a clock skew " <>
          "incident.",
      alternatives: [
        Fix.new(
          summary: "Replace duration measurement with `System.monotonic_time/1`",
          detail:
            "t0 = System.monotonic_time(:millisecond)\n" <>
              "result = work()\n" <>
              "t1 = System.monotonic_time(:millisecond)\n" <>
              "elapsed_ms = t1 - t0\n\n" <>
              "# Or use :timer.tc for one-shot timing:\n" <>
              "{microseconds, result} = :timer.tc(fn -> work() end)",
          applies_when: "Anywhere a duration is computed."
        )
      ],
      references: [
        "elixir-reviewing/SKILL.md#1.4",
        "elixir-implementing/SKILL.md#9.5"
      ],
      context: %{},
      file: file,
      line: line
    )
  end
end
