defmodule Archdo.Rules.CE.BoundaryTelemetry do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-27. Architectural boundary entry
  # points (Phoenix controller actions, Mix.Task.run/1, Oban.Worker
  # perform/1, Phoenix.Channel handlers) without `:telemetry.span` or
  # `:telemetry.execute` wrapping the work. The boundary is invisible
  # to operations: latency, error rates, throughput cannot be
  # measured; alerting and SLO tracking are impossible.
  #
  # v1 scope: scan within the function body. The spec's up-to-2-levels
  # call-graph walk is deferred (requires project-level call graph).
  # The within-body scope keeps false positives manageable but does
  # miss cases where telemetry is centralized in a Plug or wrapper.
  # Severity v1: :info to match the spec.

  alias Archdo.{AST, Diagnostic, Fix, Phoenix}

  @impl true
  def id, do: "CE-27"

  @impl true
  def description,
    do: "Architectural boundary entry point lacks :telemetry.span / :telemetry.execute"

  @impl true
  def analyze(file, ast, _opts) do
    cond do
      AST.test_file?(file) -> []
      no_telemetry_marker?(ast) -> []
      true -> find_unwrapped_boundary_entries(file, ast)
    end
  end

  defp no_telemetry_marker?(ast) do
    AST.contains?(ast, fn
      {:@, _, [{:archdo_no_telemetry, _, _}]} -> true
      _ -> false
    end)
  end

  defp find_unwrapped_boundary_entries(file, ast) do
    layer = Phoenix.classify_file(file, ast).layer
    boundary_fns = boundary_function_names(ast, layer)

    case boundary_fns do
      [] ->
        []

      _ ->
        # Multi-clause functions show up once per clause in
        # extract_functions/2. Dedupe by {name, arity}, keeping the
        # first meta seen, and check telemetry across ALL clause bodies
        # — telemetry in any clause counts as covering the function.
        ast
        |> AST.extract_functions(:public)
        |> Enum.filter(fn {n, a, _, _, _} -> {n, a} in boundary_fns end)
        |> Enum.group_by(fn {n, a, _, _, _} -> {n, a} end)
        |> Enum.flat_map(fn {{name, arity}, clauses} ->
          {_, _, meta, _, _} = hd(clauses)
          any_telemetry? = Enum.any?(clauses, fn {_, _, _, _, body} -> body && contains_telemetry?(body) end)

          case any_telemetry? do
            true -> []
            false -> [build_diagnostic(file, name, arity, meta, layer)]
          end
        end)
    end
  end

  # Per layer, return the set of {name, arity} that count as boundary
  # entry points worth wrapping in telemetry.
  defp boundary_function_names(ast, :controller) do
    # Phoenix controller actions: every public 2-arity fn taking conn +
    # params. Skip framework callbacks (action_fallback, etc.).
    ast
    |> AST.extract_functions(:public)
    |> Enum.flat_map(fn {name, arity, _, _, _} ->
      case controller_action?(name, arity) do
        true -> [{name, arity}]
        false -> []
      end
    end)
  end

  defp boundary_function_names(_ast, :live_view) do
    # LiveView mount/3, handle_event/3, handle_info/2 emit their own
    # telemetry via Phoenix.LiveView.Channel — exempt by spec.
    []
  end

  defp boundary_function_names(ast, :operational) do
    # Mix.Task — fires on run/1 and run/2 (variadic).
    case mix_task?(ast) do
      true ->
        ast
        |> AST.extract_functions(:public)
        |> Enum.flat_map(fn {name, arity, _, _, _} ->
          case name == :run do
            true -> [{name, arity}]
            false -> []
          end
        end)

      false ->
        []
    end
  end

  defp boundary_function_names(ast, _other) do
    # Oban.Worker.perform/1 — independent of layer classification
    # because workers can live anywhere under lib/.
    case oban_worker?(ast) do
      true -> [{:perform, 1}]
      false -> []
    end
  end

  defp controller_action?(name, 2) do
    # Heuristic: typical Phoenix actions are 2-arity; skip framework
    # internals named with leading underscore or known callback names.
    name not in [:action_fallback, :init, :call, :__phoenix_routes__]
  end

  defp controller_action?(_, _), do: false

  defp mix_task?(ast) do
    AST.contains?(ast, fn
      {:use, _, [{:__aliases__, _, [:Mix, :Task]}]} -> true
      {:use, _, [{:__aliases__, _, [:Mix, :Task]}, _]} -> true
      _ -> false
    end)
  end

  defp oban_worker?(ast) do
    AST.contains?(ast, fn
      {:use, _, [{:__aliases__, _, [:Oban, :Worker]}]} -> true
      {:use, _, [{:__aliases__, _, [:Oban, :Worker]}, _opts]} -> true
      _ -> false
    end)
  end

  defp contains_telemetry?(body) do
    AST.contains?(body, fn
      {{:., _, [:telemetry, fun]}, _, _} when fun in [:span, :execute] ->
        true

      {{:., _, [{:__block__, _, [:telemetry]}, fun]}, _, _} when fun in [:span, :execute] ->
        true

      _ ->
        false
    end)
  end

  defp build_diagnostic(file, name, arity, meta, layer) do
    layer_label =
      case layer do
        :controller -> "Phoenix controller action"
        :operational -> "Mix.Task callback"
        _ -> "Oban worker"
      end

    Diagnostic.info("CE-27",
      title: "Boundary entry without telemetry",
      message:
        "#{name}/#{arity}: #{layer_label} not wrapped in :telemetry.span / " <>
          ":telemetry.execute. Latency, error rates, throughput are not measurable.",
      why:
        "Architectural boundary entry points (controllers, workers, Mix tasks, " <>
          "channel handlers) are where operations care about observability: per-" <>
          "request latency, per-job duration, success/failure rates, throughput. " <>
          "Without telemetry at the boundary, none of these can be measured; " <>
          "alerting cannot be wired up; SLO tracking is impossible. CE-25 catches " <>
          "*too much* observability in domain code; CE-27 catches *none* at the " <>
          "boundary where it matters most.",
      alternatives: [
        Fix.new(
          summary: "Wrap with :telemetry.span at the boundary",
          detail:
            "`:telemetry.span([:my_app, :concern, :action], metadata, fn -> work() " <>
              "end)`. Captures start, stop, and exception events with consistent " <>
              "shape across boundaries. Standardize the event-name taxonomy " <>
              "(CE-26 catches drift if not).",
          applies_when: "The boundary owns the work directly."
        ),
        Fix.new(
          summary: "Centralize telemetry at a higher layer + mark @archdo_no_telemetry",
          detail:
            "If a Plug (or LiveView channel) emits telemetry for all routed " <>
              "requests centrally, mark this entry point: `@archdo_no_telemetry " <>
              "\"covered by MyAppWeb.Plugs.Telemetry\"`.",
          applies_when: "Observability is centralized one layer up."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-27"],
      context: %{function: "#{name}/#{arity}", layer: layer},
      file: file,
      line: AST.line(meta)
    )
  end
end
