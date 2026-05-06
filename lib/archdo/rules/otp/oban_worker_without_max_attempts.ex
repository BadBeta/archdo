defmodule Archdo.Rules.OTP.ObanWorkerWithoutMaxAttempts do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.AST.Unwrap

  @impl true
  def id, do: "5.68"

  @impl true
  def description,
    do:
      "Oban worker `use Oban.Worker` without `max_attempts:` option — falls back " <>
        "to global default and obscures the per-worker retry policy"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_workers(file, ast)
    end
  end

  defp find_workers(file, ast) do
    ast
    |> AST.find_all(&oban_worker_use?/1)
    |> Enum.flat_map(fn node -> classify(file, node) end)
  end

  defp oban_worker_use?({:use, _, [{:__aliases__, _, [:Oban, :Worker]} | _]}), do: true
  defp oban_worker_use?(_), do: false

  defp classify(file, {:use, meta, [_alias]}),
    do: [build_diagnostic(file, AST.line(meta))]

  defp classify(file, {:use, meta, [_alias, opts]}) when is_list(opts) do
    case Unwrap.kw_get(opts, :max_attempts) do
      {:ok, _} -> []
      :error -> [build_diagnostic(file, AST.line(meta))]
    end
  end

  defp classify(_file, _node), do: []

  defp build_diagnostic(file, line) do
    Diagnostic.info("5.68",
      title: "Oban.Worker without `max_attempts:` — relies on global default",
      message:
        "This `use Oban.Worker` does not set `max_attempts:`. The job inherits the " <>
          "global Oban default (20). The right `max_attempts` is highly job-specific: " <>
          "an idempotent webhook delivery may want 20+; a non-idempotent payment job " <>
          "should be 1; a flaky third-party API may want 5 with explicit backoff.",
      why:
        "Retry policy is part of the worker's contract. Leaving `max_attempts` " <>
          "implicit means the policy is set at the application config level, far " <>
          "from where the worker's retry-safety story is documented. Two failure " <>
          "modes follow: (1) the global default outlives the worker's idempotency " <>
          "design and silently runs an effectful job 20 times; (2) operators tune " <>
          "the global default for one worker and break others. Always declare the " <>
          "retry budget at the worker.",
      alternatives: [
        Fix.new(
          summary: "Set `max_attempts:` explicitly per worker",
          detail:
            "use Oban.Worker,\n" <>
              "  queue: :webhooks,\n" <>
              "  max_attempts: 5,\n" <>
              "  unique: [period: 60, fields: [:args]]\n\n" <>
              "# For non-idempotent / no-retry jobs:\n" <>
              "use Oban.Worker, queue: :payments, max_attempts: 1",
          applies_when: "Always — the retry budget is per-worker, not global."
        )
      ],
      references: ["elixir-planning/SKILL.md#7.3", "elixir-implementing/SKILL.md#9.2"],
      context: %{},
      file: file,
      line: line
    )
  end
end
