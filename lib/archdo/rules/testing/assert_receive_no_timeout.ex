defmodule Archdo.Rules.Testing.AssertReceiveNoTimeout do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "7.35"

  @impl true
  def description,
    do:
      "`assert_receive` / `refute_receive` without explicit timeout — relies on " <>
        "the 100 ms ExUnit default; size the wait to your test's actual SLO"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      false -> []
      true -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    ast
    |> AST.find_all(&untimed_assert_receive?/1)
    |> Enum.map(fn {name, meta, _} -> build_diagnostic(file, AST.line(meta), name) end)
  end

  # `assert_receive <pattern>` parses as `{:assert_receive, _, [pattern]}` (one arg).
  # `assert_receive <pattern>, timeout` parses with two args.
  defp untimed_assert_receive?({name, _, [_pattern]})
       when name in [:assert_receive, :refute_receive],
       do: true

  defp untimed_assert_receive?(_), do: false

  defp build_diagnostic(file, line, name) do
    Diagnostic.info("7.35",
      title: "`#{name}` without explicit timeout",
      message:
        "This `#{name}` call relies on ExUnit's default timeout (100 ms for " <>
          "`assert_receive`, 0 ms for `refute_receive`). On a slow CI runner " <>
          "100 ms is often too short — the message arrives 110 ms in and the " <>
          "test fails as flake. On a fast machine the same test passes. " <>
          "Specify a real timeout sized to the operation under test (1_000 ms " <>
          "for typical async work; 100 ms is enough only for true single-message " <>
          "round-trips on local code).",
      why:
        "Async tests are the leading source of flake. The default timeout was " <>
          "tuned for synchronous tests where 100 ms is generous and any wait " <>
          "longer than that is a bug. For genuinely async assertions — `Task` " <>
          "results, `:telemetry` events, GenServer side-effects, PubSub " <>
          "broadcasts — choose a timeout that's: (1) much smaller than the " <>
          "test-suite timeout (so a missed message fails fast), (2) much larger " <>
          "than the worst-case real latency (so a slow CI runner doesn't fail). " <>
          "1_000 ms is the typical sweet spot.",
      alternatives: [
        Fix.new(
          summary: "Add an explicit timeout (typically 500–2000 ms)",
          detail:
            "assert_receive {:done, _}, 1_000\n" <>
              "refute_receive {:error, _}, 200\n\n" <>
              "# Pattern with bind:\n" <>
              "assert_receive {:event, %{type: type, payload: payload}}, 1_000\n" <>
              "assert type == :completed",
          applies_when: "Always — every async assertion needs an explicit timeout."
        )
      ],
      references: ["elixir-implementing/testing-patterns.md"],
      context: %{name: name},
      file: file,
      line: line
    )
  end
end
