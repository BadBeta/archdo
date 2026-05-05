defmodule Archdo.Rules.Module.MapToMapSet do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.70"

  @impl true
  def description,
    do: "`Enum.map(coll, f) |> MapSet.new()` — use MapSet.new(coll, f) directly"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    Enum.map(AST.find_all(ast, &map_then_mapset?/1), fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta))
    end)
  end

  defp map_then_mapset?({:|>, _, [lhs, rhs]}) do
    ends_in_enum_map?(lhs) and mapset_new_call?(rhs)
  end

  defp map_then_mapset?(_), do: false

  defp ends_in_enum_map?({:|>, _, [_, rhs]}), do: enum_map_call?(rhs)
  defp ends_in_enum_map?(node), do: enum_map_call?(node)

  defp enum_map_call?({{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, args})
       when is_list(args),
       do: true

  defp enum_map_call?(_), do: false

  defp mapset_new_call?({{:., _, [{:__aliases__, _, [:MapSet]}, :new]}, _, args})
       when is_list(args),
       do: true

  defp mapset_new_call?(_), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.70",
      title: "Enum.map then MapSet.new — use MapSet.new/2 directly",
      message:
        "`Enum.map(coll, f) |> MapSet.new()` builds a list, then re-traverses it to build " <>
          "the set. `MapSet.new(coll, f)` does the transform inline during set construction.",
      why:
        "`MapSet.new/2` accepts a transformer for exactly this case. Single pass, no " <>
          "intermediate list, shorter notation. Same idea as `Map.new/2` for maps.",
      alternatives: [
        Fix.new(
          summary: "Replace with MapSet.new/2",
          detail: "MapSet.new(events, & &1.user_id)",
          applies_when: "When the result is fed into a MapSet."
        ),
        Fix.new(
          summary: "Or use a `for` comprehension with `into:`",
          detail: "for e <- events, into: MapSet.new(), do: e.user_id",
          applies_when: "When you want the comprehension form for clarity."
        )
      ],
      references: ["elixir-implementing/SKILL.md#2.2"],
      context: %{},
      file: file,
      line: line
    )
  end
end
