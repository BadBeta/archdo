defmodule Archdo.Rules.Module.FindThenTransform do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.68"

  @impl true
  def description,
    do: "`Enum.find(coll, pred) |> transform()` — use Enum.find_value/2,3"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    Enum.map(AST.find_all(ast, &find_then_pipe?/1), fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta))
    end)
  end

  # `... |> Enum.find(...) |> next()` where `next` is any call/capture.
  # The next step receives the find result (or nil); the find_value
  # form bakes the nil-handling into the predicate.
  defp find_then_pipe?({:|>, _, [lhs, _rhs]}), do: ends_in_enum_find?(lhs)
  defp find_then_pipe?(_), do: false

  defp ends_in_enum_find?({:|>, _, [_, rhs]}), do: enum_find_call?(rhs)
  defp ends_in_enum_find?(node), do: enum_find_call?(node)

  defp enum_find_call?({{:., _, [{:__aliases__, _, [:Enum]}, :find]}, _, args})
       when is_list(args),
       do: true

  defp enum_find_call?(_), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.68",
      title: "Enum.find then pipeline transform — use Enum.find_value/2,3",
      message:
        "`Enum.find(coll, pred) |> transform()` finds the matching element then handles " <>
          "nil downstream. `Enum.find_value/2,3` returns the transform's result directly " <>
          "and treats falsy as 'keep looking'.",
      why:
        "`Enum.find_value/2,3` was designed for the find-then-extract pattern. The " <>
          "predicate-and-extract collapse into one function: `fn x -> condition && extract(x) end`. " <>
          "Eliminates the explicit nil-handling step downstream and makes the intent " <>
          "(`return the first usable extraction`) explicit.",
      alternatives: [
        Fix.new(
          summary: "Replace with Enum.find_value/2,3",
          detail:
            "Enum.find_value(users, fn u -> u.active && u.id end)\n" <>
              "# Or with default: Enum.find_value(users, default, fn u -> ... end)",
          applies_when: "When the post-find pipeline step is a transform (not a side effect)."
        )
      ],
      references: ["elixir-implementing/SKILL.md#2.2"],
      context: %{},
      file: file,
      line: line
    )
  end
end
