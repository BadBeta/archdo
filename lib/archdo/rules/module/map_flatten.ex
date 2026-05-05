defmodule Archdo.Rules.Module.MapFlatten do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.69"

  @impl true
  def description,
    do: "`Enum.map(coll, f) |> List.flatten()` — use Enum.flat_map/2"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    Enum.map(AST.find_all(ast, &map_then_flatten?/1), fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta))
    end)
  end

  # `... |> Enum.map(...) |> List.flatten()` (or `:lists.flatten`).
  defp map_then_flatten?({:|>, _, [lhs, rhs]}) do
    ends_in_enum_map?(lhs) and flatten_call?(rhs)
  end

  defp map_then_flatten?(_), do: false

  defp ends_in_enum_map?({:|>, _, [_, rhs]}), do: enum_map_call?(rhs)
  defp ends_in_enum_map?(node), do: enum_map_call?(node)

  defp enum_map_call?({{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, args})
       when is_list(args),
       do: true

  defp enum_map_call?(_), do: false

  defp flatten_call?({{:., _, [{:__aliases__, _, [:List]}, :flatten]}, _, _}), do: true
  defp flatten_call?({{:., _, [:lists, :flatten]}, _, _}), do: true
  defp flatten_call?(_), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.69",
      title: "Enum.map then List.flatten — use Enum.flat_map/2",
      message:
        "`Enum.map(coll, f) |> List.flatten()` traverses the collection twice and " <>
          "constructs an intermediate nested list. `Enum.flat_map/2` does both passes in one.",
      why:
        "`Enum.flat_map/2` is the canonical form for 'transform each element to a list, " <>
          "then concatenate the results'. Single pass, lower allocation, intent obvious " <>
          "from the function name.",
      alternatives: [
        Fix.new(
          summary: "Replace with Enum.flat_map/2",
          detail: "Enum.flat_map(posts, & &1.tags)",
          applies_when: "When the map step's output is a list per element."
        )
      ],
      references: ["elixir-implementing/SKILL.md#2.2"],
      context: %{},
      file: file,
      line: line
    )
  end
end
