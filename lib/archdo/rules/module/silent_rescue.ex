defmodule Archdo.Rules.Module.SilentRescue do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.80"

  @impl true
  def description,
    do: "rescue clause silently swallows the exception (no log, no re-raise, no message)"

  # Atoms / values returned from a rescue clause that constitute a
  # silent swallow. We treat anything that ISN'T paired with a log
  # call or re-raise as silent.
  @silent_returns [nil, :error, :ok, false, true]

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    AST.find_all(ast, &try_with_silent_rescue?/1)
    |> Enum.flat_map(fn {:try, _, args} -> silent_clause_lines(args) end)
    |> Enum.map(fn line -> build_diagnostic(file, line) end)
  end

  defp try_with_silent_rescue?({:try, _, args}) when is_list(args) do
    silent_clause_lines(args) != []
  end

  defp try_with_silent_rescue?(_), do: false

  defp silent_clause_lines(args) do
    rescue_clauses =
      Enum.find_value(args, [], fn
        kw when is_list(kw) -> Keyword.get(kw, :rescue, [])
        _ -> nil
      end)

    rescue_clauses
    |> Enum.filter(&silent_clause?/1)
    |> Enum.map(fn {:->, meta, _} -> AST.line(meta) end)
  end

  # `rescue _ -> nil` / `rescue _ -> :error` etc. — clause body is a
  # bare silent value (no Logger, no raise, no reraise).
  defp silent_clause?({:->, _, [_pattern, body]}) do
    silent_body?(body)
  end

  defp silent_clause?(_), do: false

  defp silent_body?(value) when value in @silent_returns, do: true

  # `{:error, _}` — silent if the body is a bare 2-tuple of `:error`
  # plus a literal / variable, no logging.
  defp silent_body?({:error, _}), do: true

  defp silent_body?({:__block__, _, exprs}) when is_list(exprs) do
    not contains_logger_or_raise?(exprs) and silent_terminal?(List.last(exprs))
  end

  defp silent_body?(_), do: false

  defp silent_terminal?(value) when value in @silent_returns, do: true
  defp silent_terminal?({:error, _}), do: true
  defp silent_terminal?(_), do: false

  defp contains_logger_or_raise?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, [:Logger]}, _fn]}, _, _} = node, _ -> {node, true}
        {:raise, _, _} = node, _ -> {node, true}
        {:reraise, _, _} = node, _ -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  defp build_diagnostic(file, line) do
    Diagnostic.warning("6.80",
      title: "Silent rescue — exception swallowed without log or re-raise",
      message:
        "This rescue clause silently turns the exception into `nil` / `:error` / `false` " <>
          "without logging or re-raising. The exception's information is lost; the " <>
          "operator has no way to learn the cause when the path executes in production.",
      why:
        "Silent rescues are how production debugging gets hard. The exception carries the " <>
          "stack trace, the bound exception value, and the cause; converting that to `nil` " <>
          "discards all of it. Even if the caller wants to handle the failure as `nil`, " <>
          "log first, then return — the operator needs the trace to diagnose recurrence.",
      alternatives: [
        Fix.new(
          summary: "Log the exception with stacktrace, then return the failure value",
          detail:
            "rescue\n" <>
              "  e ->\n" <>
              "    Logger.error(Exception.format(:error, e, __STACKTRACE__))\n" <>
              "    nil",
          applies_when: "When the caller's API genuinely is `value | nil` / `:ok | :error`."
        ),
        Fix.new(
          summary: "Or rescue specific exceptions (don't blanket-catch)",
          detail:
            "rescue\n" <>
              "  e in [Ecto.NoResultsError] -> nil\n" <>
              "  # Other exceptions propagate — let supervisor handle.",
          applies_when: "When you know exactly which exceptions are expected here."
        )
      ],
      references: ["elixir-implementing/SKILL.md#7.4", "elixir-implementing/SKILL.md#8.2"],
      context: %{},
      file: file,
      line: line
    )
  end
end
