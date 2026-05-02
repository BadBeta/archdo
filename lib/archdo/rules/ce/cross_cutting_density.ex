defmodule Archdo.Rules.CE.CrossCuttingDensity do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-25. A function whose body is dominated
  # by calls into known cross-cutting concerns (Logger, telemetry,
  # Repo.transaction, Ecto.Multi, retry/breaker libs). The domain
  # intent is buried under aspect noise; every aspect change ripples
  # across these functions. The fix is a bracket helper or a Plug-like
  # pipeline at one consistent layer.

  alias Archdo.{AST, Diagnostic, Fix}

  # Density above this fires; below is normal cross-cutting use.
  @density_threshold 0.40
  # Tiny functions trigger noise — only inspect functions of meaningful size.
  @min_body_size 5

  @impl true
  def id, do: "CE-25"

  @impl true
  def description,
    do: "Function body dominated by cross-cutting calls (Logger, telemetry, transactions, retry)"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_dense(file, ast)
    end
  end

  defp find_dense(file, ast) do
    aggregator? = AST.has_marker?(ast, :archdo_aspect_aggregator)

    case aggregator? do
      true ->
        []

      false ->
        ast
        |> AST.extract_functions(:public)
        |> Enum.flat_map(&maybe_diagnostic(file, &1))
    end
  end

  defp maybe_diagnostic(file, {name, arity, meta, _args, body}) do
    statements = body_statements(body)
    total = length(statements)

    case total >= @min_body_size do
      false ->
        []

      true ->
        {cross_count, categories} = classify_statements(statements)
        density = cross_count / total

        case density > @density_threshold do
          true -> [build_diagnostic(file, name, arity, meta, density, categories, total)]
          false -> []
        end
    end
  end

  # Body comes from extract_functions/2 as the def's keyword list. Under
  # literal_encoder (used by the runner) the `:do` key itself is wrapped
  # as `{:__block__, _, [:do]}`; AST.do_body/1 handles both shapes.
  defp body_statements(body) when is_list(body) do
    case AST.do_body(body) do
      nil -> []
      {:__block__, _, statements} when is_list(statements) -> statements
      single -> [single]
    end
  end

  defp body_statements({:__block__, _, statements}) when is_list(statements), do: statements
  defp body_statements(single), do: [single]

  defp classify_statements(statements) do
    Enum.reduce(statements, {0, MapSet.new()}, fn stmt, {n, cats} ->
      case classify_call(stmt) do
        nil -> {n, cats}
        cat -> {n + 1, MapSet.put(cats, cat)}
      end
    end)
  end

  # The runner parses with literal_encoder, which wraps atoms as
  # `{:__block__, _, [:atom]}`. Test ASTs (Code.string_to_quoted/1
  # without encoder) use raw atoms. Normalize the call's first dotted
  # element so both shapes match.

  defp classify_call({{:., _, [target, fun]}, _, _}) do
    classify_target(unwrap_atom(target), fun)
  end

  defp classify_call(_), do: nil

  defp unwrap_atom({:__block__, _, [a]}) when is_atom(a), do: a
  defp unwrap_atom(other), do: other

  # Logger.x(...)
  defp classify_target({:__aliases__, _, [:Logger]}, _), do: "Logger"

  # :telemetry.x(...) / :telemetry_metrics.x(...)
  defp classify_target(:telemetry, _), do: ":telemetry"
  defp classify_target(:telemetry_metrics, _), do: ":telemetry_metrics"

  # Repo.transaction(...) / X.Repo.transaction(...)
  defp classify_target({:__aliases__, _, parts}, :transaction) when is_list(parts) do
    case List.last(parts) == :Repo do
      true -> "Repo.transaction"
      false -> nil
    end
  end

  # Ecto.Multi.x(...) / Multi.x(...)
  defp classify_target({:__aliases__, _, [:Ecto, :Multi]}, _), do: "Ecto.Multi"
  defp classify_target({:__aliases__, _, [:Multi]}, _), do: "Ecto.Multi"

  # Retry.with_retries(...) / Retry.retry(...)
  defp classify_target({:__aliases__, _, [:Retry]}, _), do: "Retry"

  # Fuse.x(...) / :fuse.x(...)
  defp classify_target({:__aliases__, _, [:Fuse]}, _), do: "Fuse"
  defp classify_target(:fuse, _), do: ":fuse"

  defp classify_target(_, _), do: nil

  defp build_diagnostic(file, name, arity, meta, density, categories, total) do
    cats = categories |> Enum.sort() |> Enum.join(", ")
    pct = (density * 100) |> Float.round(0) |> trunc()

    Diagnostic.warning("CE-25",
      title: "Function dominated by cross-cutting concerns",
      message:
        "#{name}/#{arity}: #{pct}% of #{total} body expressions are calls into " <>
          "cross-cutting modules (#{cats}). Domain intent is buried under aspect noise.",
      why:
        "When more than #{trunc(@density_threshold * 100)}% of a function's body is " <>
          "Logger / telemetry / transaction / retry plumbing, the function reads as " <>
          "'do this set of cross-cutting things, and somewhere in the middle do the " <>
          "actual work.' Adding a new aspect (rate-limit, idempotency token) requires " <>
          "editing every such function. Removing an aspect requires the same. The " <>
          "abstraction missing here is a bracket helper or a Plug-like pipeline at " <>
          "one consistent layer.",
      alternatives: [
        Fix.new(
          summary: "Wrap with :telemetry.span at one consistent layer",
          detail:
            "Move telemetry/logging to the controller or context entry, not both. " <>
              "`:telemetry.span([:app, :concern, :action], meta, fn -> work() end)` " <>
              "captures start/stop/exception in one call.",
          applies_when: "The dominating aspect is observability (telemetry/logging)."
        ),
        Fix.new(
          summary: "Pull Repo.transaction up; rebuild as Ecto.Multi",
          detail:
            "Make the inner function pure — return an Ecto.Multi or a description " <>
              "value. The transaction wraps the value at the caller, not the callee. " <>
              "Inner function becomes testable without sandboxing.",
          applies_when: "The dominating aspect is transaction management."
        ),
        Fix.new(
          summary: "Mark as aspect aggregator if this IS the bracket",
          detail:
            "If the function's job is to wrap concerns (a `with_logging/2` helper, a " <>
              "`tracked/3` wrapper), declare the contract: add " <>
              "`@archdo_aspect_aggregator true` at module level.",
          applies_when: "The function is genuinely the cross-cutting wrapper."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-25"],
      context: %{
        function: "#{name}/#{arity}",
        density: density,
        body_size: total,
        categories: Enum.sort(MapSet.to_list(categories))
      },
      file: file,
      line: AST.line(meta)
    )
  end
end
