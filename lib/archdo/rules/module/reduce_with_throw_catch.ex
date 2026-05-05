defmodule Archdo.Rules.Module.ReduceWithThrowCatch do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.60"

  @impl true
  def description,
    do: "Enum.reduce with throw/catch for early exit — use Enum.reduce_while/3"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    Enum.map(AST.find_all(ast, &reduce_in_try_catch?/1), fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta))
    end)
  end

  # `try do <body containing Enum.reduce with throw> ... catch ... end`
  # The whole try-block is the violation.
  defp reduce_in_try_catch?({:try, _, args}) when is_list(args) do
    body = try_body(args)
    has_catch?(args) and contains_reduce_with_throw?(body)
  end

  defp reduce_in_try_catch?(_), do: false

  defp try_body(args) do
    Enum.find_value(args, [], fn
      [{:do, body} | _] -> body
      _ -> nil
    end)
  end

  defp has_catch?(args) do
    Enum.any?(args, fn
      kw when is_list(kw) -> Keyword.has_key?(kw, :catch)
      _ -> false
    end)
  end

  defp contains_reduce_with_throw?(body) do
    {_, found?} =
      Macro.prewalk(body, false, fn
        {{:., _, [{:__aliases__, _, [:Enum]}, :reduce]}, _, args} = node, _acc
        when is_list(args) ->
          {node, contains_throw?(args)}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp contains_throw?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {:throw, _, _} = node, _acc -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.60",
      title: "Enum.reduce with throw/catch — use Enum.reduce_while/3",
      message:
        "Enum.reduce inside try/catch with throw for early exit — Enum.reduce_while/3 " <>
          "expresses the same intent without the exception machinery.",
      why:
        "Enum.reduce_while/3 was added specifically for early termination from a reducer. " <>
          "The throw/catch pattern works but adds runtime cost (throw constructs an " <>
          "exception, catch unwinds the stack), and it obscures the intent: a reader has to " <>
          "trace `throw {:found, ...}` to the matching catch clause. `reduce_while` keeps " <>
          "the early-exit signal `{:halt, value}` next to the value being returned.",
      alternatives: [
        Fix.new(
          summary: "Replace with Enum.reduce_while/3",
          detail:
            "`Enum.reduce_while(items, init, fn item, acc -> ... end)` returns " <>
              "`{:halt, value}` to stop early or `{:cont, acc}` to continue. The final " <>
              "result is the last halted-value or the final-cont accumulator.",
          applies_when: "When the reducer can decide locally whether to stop."
        )
      ],
      references: ["elixir-implementing/SKILL.md#2.1"],
      context: %{},
      file: file,
      line: line
    )
  end
end
