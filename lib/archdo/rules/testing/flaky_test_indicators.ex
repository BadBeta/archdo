defmodule Archdo.Rules.Testing.FlakyTestIndicators do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "7.29"

  @impl true
  def description, do: "Test patterns that commonly cause flakiness"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      false -> []
      true -> find_flaky_patterns(file, ast)
    end
  end

  defp find_flaky_patterns(file, ast) do
    assert_receive_no_timeout(file, ast) ++
      non_deterministic_random(file, ast) ++
      time_dependent_assertions(file, ast)
  end

  # assert_receive with only 1 arg (pattern) — no explicit timeout
  defp assert_receive_no_timeout(file, ast) do
    ast
    |> AST.find_all(fn
      {:assert_receive, _, [_pattern]} -> true
      _ -> false
    end)
    |> Enum.map(fn {_, meta, _} ->
      Diagnostic.info("7.29",
        title: "assert_receive without explicit timeout",
        message: "assert_receive uses default 100ms timeout — specify an explicit timeout",
        why:
          "The default assert_receive timeout is 100ms, which is often too short on CI servers " <>
            "or under load. Tests pass locally but fail intermittently in CI. An explicit timeout " <>
            "documents the expected latency and makes the test resilient to varying execution speed.",
        alternatives: [
          Fix.new(
            summary: "Add an explicit timeout",
            detail:
              "Change `assert_receive pattern` to `assert_receive pattern, 1_000` (or an " <>
                "appropriate timeout for the operation). Choose a timeout that is generous " <>
                "enough for slow CI but short enough to catch real hangs.",
            applies_when: "The async operation has a known expected latency."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#7.29"],
        context: %{pattern: "assert_receive_no_timeout"},
        file: file,
        line: AST.line(meta)
      )
    end)
  end

  # :rand.uniform or Enum.random in tests — non-deterministic
  defp non_deterministic_random(file, ast) do
    ast
    |> AST.find_all(fn
      {{:., _, [:rand, :uniform]}, _, _} -> true
      {{:., _, [{:__aliases__, _, [:Enum]}, :random]}, _, _} -> true
      _ -> false
    end)
    |> Enum.map(fn node ->
      meta = elem(node, 1)
      pattern_name = random_pattern_name(node)

      Diagnostic.info("7.29",
        title: "Non-deterministic random in test",
        message: "#{pattern_name} makes test output non-reproducible",
        why:
          "Random values in tests make failures non-reproducible. A test that fails once " <>
            "may pass on re-run with different random values, hiding real bugs. If you need " <>
            "randomized test data, seed the random generator deterministically or use property-based " <>
            "testing (StreamData) which tracks seeds for replay.",
        alternatives: [
          Fix.new(
            summary: "Use fixed test data or a seeded generator",
            detail:
              "Replace random values with fixed test data. If you need variety, use " <>
                "StreamData for property-based testing — it tracks seeds so failures are reproducible.",
            applies_when: "The test uses random data for variety."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#7.29"],
        context: %{pattern: "non_deterministic_random"},
        file: file,
        line: AST.line(meta)
      )
    end)
  end

  defp random_pattern_name({{:., _, [:rand, :uniform]}, _, _}), do: ":rand.uniform"

  defp random_pattern_name({{:., _, [{:__aliases__, _, [:Enum]}, :random]}, _, _}),
    do: "Enum.random"

  defp random_pattern_name(_), do: "random call"

  # Time-dependent assertions
  defp time_dependent_assertions(file, ast) do
    ast
    |> AST.find_all(fn
      {{:., _, [{:__aliases__, _, [:System]}, :monotonic_time]}, _, _} -> true
      {{:., _, [{:__aliases__, _, [:DateTime]}, :utc_now]}, _, _} -> true
      _ -> false
    end)
    |> Enum.map(fn node ->
      meta = elem(node, 1)
      pattern_name = time_pattern_name(node)

      Diagnostic.info("7.29",
        title: "Time-dependent test assertion",
        message: "#{pattern_name} in test — timing-dependent assertions are flaky",
        why:
          "Tests that capture the current time and assert on it are sensitive to execution " <>
            "speed. A test that asserts `result.timestamp == DateTime.utc_now()` will fail if " <>
            "there's any delay between the two calls. On slow CI or under garbage collection " <>
            "pressure, these tests fail intermittently.",
        alternatives: [
          Fix.new(
            summary: "Inject time as a dependency",
            detail:
              "Pass the current time as a parameter or use a time module behind a behaviour. " <>
                "In tests, inject a fixed time. This makes assertions deterministic.",
            applies_when: "The code under test uses the current time."
          ),
          Fix.new(
            summary: "Assert on time ranges instead of exact values",
            detail:
              "If you must use real time, assert that the timestamp falls within a range: " <>
                "`assert DateTime.diff(result.time, before_time, :second) < 5`.",
            applies_when: "Exact time comparison is not required."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#7.29"],
        context: %{pattern: "time_dependent_assertion"},
        file: file,
        line: AST.line(meta)
      )
    end)
  end

  defp time_pattern_name({{:., _, [{:__aliases__, _, [:System]}, :monotonic_time]}, _, _}),
    do: "System.monotonic_time"

  defp time_pattern_name({{:., _, [{:__aliases__, _, [:DateTime]}, :utc_now]}, _, _}),
    do: "DateTime.utc_now"

  defp time_pattern_name(_), do: "time call"
end
