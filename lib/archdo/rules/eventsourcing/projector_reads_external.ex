defmodule Archdo.Rules.EventSourcing.ProjectorReadsExternal do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "8.6"

  @impl true
  def description,
    do: "Projectors must not call HTTP/external services or non-deterministic functions"

  @impl true
  def analyze(file, ast, _opts) do
    case projector_module?(ast) do
      false -> []
      true -> find_external_reads(file, ast)
    end
  end

  # Projectors use `project(%Event{} = event, _metadata, fn multi -> ... end)`.
  # They CAN read from their own projection table via Repo.get (common pattern
  # for load-then-update). The real anti-patterns are:
  #   - HTTP calls (breaks replay determinism)
  #   - Non-deterministic time/random (replay produces different results)
  #   - Reading another module's projection (cross-projection coupling)
  #
  # We're strict about HTTP + non-determinism; we don't flag Repo.get because
  # it's legitimately used to load the projection's own state.
  defp find_external_reads(file, ast) do
    projects = find_project_calls(ast)

    Enum.flat_map(projects, fn {_meta, body} ->
      find_http_calls(body, file) ++ find_nondeterministic(body, file)
    end)
  end

  defp find_project_calls(ast) do
    Enum.map(
      AST.find_all(ast, fn
        {:project, _, _} -> true
        _ -> false
      end),
      fn {:project, meta, args} -> {meta, args} end
    )
  end

  defp find_nondeterministic(body, file) do
    Enum.map(
      AST.find_all(body, fn
        # DateTime.utc_now/0 — value changes on replay
        {{:., _, [{:__aliases__, _, [mod]}, func]}, _, _} ->
          mod in [:DateTime, :NaiveDateTime, :Date, :Time] and
            func in [:utc_now, :utc_today, :now]

        # System.system_time, :rand.uniform, etc.
        {{:., _, [{:__aliases__, _, [:System]}, func]}, _, _}
        when func in [:system_time, :monotonic_time, :os_time] ->
          true

        {{:., _, [:rand, _]}, _, _} ->
          true

        _ ->
          false
      end),
      fn {_, meta, _} = node ->
        desc =
          case node do
            {{:., _, [{:__aliases__, _, mod}, func]}, _, _} ->
              "#{Enum.join(mod, ".")}.#{func}"

            {{:., _, [mod, func]}, _, _} when is_atom(mod) ->
              ":#{mod}.#{func}"

            _ ->
              "non-deterministic call"
          end

        Diagnostic.warning("8.6",
          title: "Non-deterministic call in projector",
          message: "Projector calls #{desc} inside a project/3 callback",
          why:
            "Projectors are run again whenever a read model is rebuilt from the event stream. Non-deterministic " <>
              "calls (`DateTime.utc_now`, `:rand.uniform`, `System.system_time`) return different values on each " <>
              "replay, so the rebuilt projection no longer matches the original — and the discrepancy is invisible until somebody compares.",
          alternatives: [
            Fix.new(
              summary: "Capture the value on the event when it is first emitted",
              detail:
                "Move the call into the command handler that produced the event, store the result as an event " <>
                  "field (e.g. `occurred_at`), and read it back from the event in the projector. The same event " <>
                  "now produces the same projection on every replay.",
              example: """
              ```elixir
              # in the aggregate
              def execute(state, %CreateAccount{} = cmd) do
                %AccountCreated{id: cmd.id, occurred_at: DateTime.utc_now()}
              end

              # in the projector
              def project(%AccountCreated{occurred_at: at} = ev, _meta, fn ->
                # use `at` directly — replay-safe
              end)
              ```
              """,
              applies_when: "The value is determined when the event is first produced."
            ),
            Fix.new(
              summary: "Use the event metadata's timestamp instead of calling the clock",
              detail:
                "Commanded passes a metadata map to project/3 that already contains the event's `created_at`. " <>
                  "If you need a wall-clock timestamp, read it from there — it is fixed at write time.",
              applies_when: "You only need the event's own timestamp."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#8.6"],
          context: %{call: desc, kind: :nondeterministic},
          file: file,
          line: AST.line(meta)
        )
      end
    )
  end

  defp find_http_calls(body, file) do
    Enum.map(
      AST.find_all(body, fn
        {{:., _, [{:__aliases__, _, mod_parts}, _func]}, _, _} ->
          Module.concat(mod_parts) in [HTTPoison, Finch, Req, Tesla]

        _ ->
          false
      end),
      fn {{:., _, [{:__aliases__, _, mod_parts}, func]}, meta, _} ->
        call = "#{Enum.join(mod_parts, ".")}.#{func}"

        Diagnostic.warning("8.6",
          title: "HTTP call in projector",
          message: "Projector calls #{call} inside a project/3 callback",
          why:
            "Projectors are replayed against the event log to rebuild read models. An HTTP call talks to a " <>
              "remote service whose response can change, time out, or simply return different data than it did " <>
              "the first time the event was processed. The rebuilt projection no longer matches the original and the divergence is silent.",
          alternatives: [
            Fix.new(
              summary:
                "Move the HTTP call to a separate event handler that updates the projection later",
              detail:
                "Event handlers (not projectors) are the right place for side effects. Have the handler perform " <>
                  "the HTTP call, then emit a new event (e.g. `EnrichmentLoaded`) that the projector consumes. " <>
                  "Replays now read the persisted enrichment fact instead of re-fetching it.",
              applies_when: "The remote data is dynamic and can change after the original event."
            ),
            Fix.new(
              summary: "Cache the response on the originating event",
              detail:
                "If the data is small and effectively immutable per-event (e.g. user-agent parsing), capture it " <>
                  "in the command handler and persist it as an event field. The projector then reads the field " <>
                  "directly with no network call.",
              applies_when: "The remote data is static given the event payload."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#8.6"],
          context: %{call: call, kind: :http},
          file: file,
          line: AST.line(meta)
        )
      end
    )
  end

  defp projector_module?(ast) do
    AST.contains?(ast, fn
      {:use, _, [{:__aliases__, _, [:Commanded, :Projections, :Ecto]} | _]} -> true
      _ -> false
    end)
  end
end
