defmodule Archdo.Rules.Module.ManualTaskAwaitList do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.64"

  @impl true
  def description,
    do: "`Enum.map(coll, &Task.async/1) |> Enum.map(&Task.await/1)` — use Task.async_stream/3,5"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    Enum.map(AST.find_all(ast, &task_async_then_await?/1), fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta))
    end)
  end

  # `... |> Enum.map(<task_async_capture>) |> Enum.map(<task_await_capture>)`
  defp task_async_then_await?({:|>, _, [lhs, rhs]}) do
    ends_in_enum_map_with_task_async?(lhs) and enum_map_with_task_await?(rhs)
  end

  defp task_async_then_await?(_), do: false

  defp ends_in_enum_map_with_task_async?({:|>, _, [_, rhs]}),
    do: enum_map_with_task_async?(rhs)

  defp ends_in_enum_map_with_task_async?(node), do: enum_map_with_task_async?(node)

  defp enum_map_with_task_async?({{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, args})
       when is_list(args) do
    case List.last(args) do
      nil -> false
      arg -> contains_task_async?(arg)
    end
  end

  defp enum_map_with_task_async?(_), do: false

  defp enum_map_with_task_await?({{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, args})
       when is_list(args) do
    case List.last(args) do
      nil -> false
      arg -> contains_task_await?(arg)
    end
  end

  defp enum_map_with_task_await?(_), do: false

  defp contains_task_async?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, [:Task]}, :async]}, _, _} = node, _ -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  defp contains_task_await?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, [:Task]}, :await]}, _, _} = node, _ -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  defp build_diagnostic(file, line) do
    Diagnostic.info("5.64",
      title: "Manual Task.async + Task.await — use Task.async_stream/3,5",
      message:
        "Pipeline maps `Task.async` then maps `Task.await` over the same collection. " <>
          "`Task.async_stream/3,5` does both with built-in concurrency control, backpressure, " <>
          "and timeout handling.",
      why:
        "The manual pattern works but: (1) starts ALL tasks at once with no concurrency " <>
          "limit, (2) gives no per-task timeout, (3) doesn't handle task crashes gracefully. " <>
          "`Task.async_stream` adds `:max_concurrency`, `:timeout`, `:on_timeout`, and " <>
          "`:ordered` options out of the box.",
      alternatives: [
        Fix.new(
          summary: "Replace with Task.async_stream/3,5",
          detail:
            "urls\n" <>
              "|> Task.async_stream(&fetch/1, timeout: 10_000, max_concurrency: 8)\n" <>
              "|> Enum.map(fn {:ok, result} -> result end)",
          applies_when:
            "When the parallel work is independent and you can express it as fn(elem) -> result"
        )
      ],
      references: ["elixir-implementing/SKILL.md#2.9", "elixir-implementing/SKILL.md#9.9"],
      context: %{},
      file: file,
      line: line
    )
  end
end
