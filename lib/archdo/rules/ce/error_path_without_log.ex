defmodule Archdo.Rules.CE.ErrorPathWithoutLog do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-28. A function that returns an
  # `{:error, _}` literal or contains a `rescue` clause but emits no
  # log entry. Errors disappear silently — debugging requires
  # reproducing the path, alerting cannot fire on patterns the logs
  # don't expose. Fix: add `Logger.error/warning` with structured
  # metadata at the error introduction site.
  #
  # v1 scope: scan within the function body itself; the up-to-2-levels
  # static call-graph walk in the spec is deferred (requires a
  # project-level call graph). Within-body scope produces low false
  # positives — pass-through wrappers stay clean because they don't
  # contain the error literal.

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "CE-28"

  @impl true
  def description,
    do: "Function returns {:error, _} or has rescue without an in-scope Logger call"

  @impl true
  def analyze(file, ast, opts) do
    cond do
      AST.test_file?(file) -> []
      AST.has_marker?(ast, :archdo_silent_error) -> []
      # §§ M-Plan7 — project-level log-plug exemption. If any plug in
      # the project emits Logger calls, error logging is centralized at
      # the request boundary; per-function log calls are not required.
      covering_log_plug(opts) != nil -> []
      true -> find_unlogged_errors(file, ast)
    end
  end

  defp covering_log_plug(opts) do
    case Keyword.get(opts, :plug_coverage) do
      %{log_plugs: [plug | _]} -> plug
      _ -> nil
    end
  end

  defp find_unlogged_errors(file, ast) do
    ast
    |> AST.extract_functions(:public)
    |> Enum.flat_map(fn {name, arity, meta, _args, body} ->
      case body && needs_log?(body) do
        true -> [build_diagnostic(file, name, arity, meta)]
        _ -> []
      end
    end)
  end

  defp needs_log?(body) do
    error_path?(body) and not AST.contains_logger?(body)
  end

  # Body has a literal `{:error, _}` return OR a rescue clause.
  defp error_path?(body) do
    contains_error_literal?(body) or has_rescue_clause?(body)
  end

  # Walks the body looking for a literal `{:error, _}` 2-tuple.
  # Two AST shapes:
  #   - bare parser:           {:error, reason}
  #   - literal_encoder parser: {{:__block__, _, [:error]}, reason}
  defp contains_error_literal?(body) do
    {_, hit?} =
      Macro.prewalk(body, false, fn
        node, true ->
          {node, true}

        {{:__block__, _, [:error]}, _reason} = node, false ->
          {node, true}

        {:error, _reason} = node, false ->
          {node, true}

        # 3+ element tuples (3-tuple shape used for function calls):
        # {:{}, meta, [:error, reason]} or with __block__-wrapped :error
        {:{}, _, [{:__block__, _, [:error]} | [_reason]]} = node, false ->
          {node, true}

        {:{}, _, [:error | [_reason]]} = node, false ->
          {node, true}

        node, false ->
          {node, false}
      end)

    hit?
  end

  defp has_rescue_clause?(body) do
    AST.contains?(body, fn
      {:try, _, kw_list} when is_list(kw_list) ->
        Enum.any?(kw_list, fn
          {:rescue, _} -> true
          {{:__block__, _, [:rescue]}, _} -> true
          _ -> false
        end)

      # def fn ... rescue ... end shape: keyword list at body level
      kw when is_list(kw) ->
        Enum.any?(kw, fn
          {:rescue, _} -> true
          {{:__block__, _, [:rescue]}, _} -> true
          _ -> false
        end)

      _ ->
        false
    end)
  end

  defp build_diagnostic(file, name, arity, meta) do
    # v1 severity: :info. The spec calls for warning, but without the
    # up-to-2-levels call-graph walk that filters out normal-control-
    # flow errors caught at a higher boundary, warning over-fires
    # heavily on idiomatic context functions returning Ecto changesets.
    # When the call-graph walk lands, severity can be raised.
    Diagnostic.info("CE-28",
      title: "Error path without log",
      message:
        "#{name}/#{arity} returns {:error, _} (or has a rescue clause) but emits " <>
          "no Logger call — errors disappear silently",
      why:
        "When error introduction sites don't log, debugging requires reproducing " <>
          "the path; alerting cannot fire on patterns the logs don't expose; " <>
          "production support is reactive instead of proactive. The cost compounds " <>
          "in distributed systems where reproduction is expensive.",
      alternatives: [
        Fix.new(
          summary: "Log with structured metadata at the introduction site",
          detail:
            "`Logger.error(\"failed to do X\", error: reason, context: %{...})`. " <>
              "Use structured fields, not string interpolation — log aggregators " <>
              "can search and aggregate on fields but not on formatted strings.",
          applies_when: "The error is unexpected and worth surfacing in logs."
        ),
        Fix.new(
          summary: "Mark @archdo_silent_error if the error is normal control flow",
          detail:
            "If `{:error, :not_found}` is a domain answer (caller's normal " <>
              "control flow), declare it: `@archdo_silent_error \"reason\"` at " <>
              "module level. This documents intent and silences CE-28.",
          applies_when: "The error is part of the function's contract, not a failure."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-28"],
      context: %{function: "#{name}/#{arity}"},
      file: file,
      line: AST.line(meta)
    )
  end
end
