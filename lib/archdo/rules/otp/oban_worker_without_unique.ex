defmodule Archdo.Rules.OTP.ObanWorkerWithoutUnique do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.AST.Unwrap

  @impl true
  def id, do: "5.67"

  @impl true
  def description,
    do:
      "Oban worker `use Oban.Worker` without `unique:` option — duplicate enqueues " <>
        "execute as separate jobs, breaking idempotency for retryable work"

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

  defp classify(file, {:use, meta, [_alias]} = _node),
    do: [build_diagnostic(file, AST.line(meta))]

  defp classify(file, {:use, meta, [_alias, opts]} = _node) when is_list(opts) do
    case Unwrap.kw_get(opts, :unique) do
      {:ok, _} -> []
      :error -> [build_diagnostic(file, AST.line(meta))]
    end
  end

  defp classify(_file, _node), do: []

  defp build_diagnostic(file, line) do
    Diagnostic.info("5.67",
      title: "Oban.Worker without `unique:` — duplicate enqueues run independently",
      message:
        "This `use Oban.Worker` does not set the `unique:` option. Without it, two " <>
          "calls to `MyWorker.new(args) |> Oban.insert()` enqueue two separate jobs — " <>
          "and on Oban retry, a transient producer-side retry (network blip, request " <>
          "retry, double-click) becomes a duplicated job execution.",
      why:
        "Oban automatically retries jobs on failure (up to `max_attempts`). If the job " <>
          "is not idempotent — e.g., charges a card, sends an email, increments a " <>
          "counter — every retry compounds. The `unique:` option lets Oban dedupe " <>
          "enqueues based on arg hash, scope, and a time window. Combined with an " <>
          "idempotent `perform/1` body (deterministic on `Oban.Job.id` or some " <>
          "business key), `unique:` plus retries gives at-least-once semantics that " <>
          "behave like exactly-once for the user.",
      alternatives: [
        Fix.new(
          summary: "Add a `unique:` window matching the job's safe-retry interval",
          detail:
            "use Oban.Worker,\n" <>
              "  queue: :mailers,\n" <>
              "  max_attempts: 3,\n" <>
              "  # Within 5 min, the same args (same user_id, same template) cannot\n" <>
              "  # be enqueued twice. Adjust :period to your business deduplication\n" <>
              "  # window. :fields can be [:args], [:worker, :args], or [:args, :queue].\n" <>
              "  unique: [period: 300, fields: [:args]]",
          applies_when:
            "When the job is producer-side retryable (HTTP webhook, button click, scheduled task)."
        ),
        Fix.new(
          summary: "Or document why uniqueness is not needed",
          detail:
            "If the worker is internally idempotent (e.g., upsert by primary key, " <>
              "no-op on second run) and producers cannot duplicate enqueues, leave a " <>
              "moduledoc line explaining the dedup story so future readers don't add " <>
              "`unique:` defensively.",
          applies_when:
            "When the worker's effects are intrinsically idempotent and producers are dedup-safe."
        )
      ],
      references: [
        "elixir-planning/SKILL.md#7.3",
        "elixir-implementing/SKILL.md#9.2"
      ],
      context: %{},
      file: file,
      line: line
    )
  end
end
