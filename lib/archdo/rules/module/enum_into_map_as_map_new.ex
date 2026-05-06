defmodule Archdo.Rules.Module.EnumIntoMapAsMapNew do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.91"

  @impl true
  def description,
    do: "`Enum.into(coll, %{})` / `Enum.into(coll, %{}, fun)` — use `Map.new/1,2`"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_calls(file, ast)
    end
  end

  defp find_calls(file, ast) do
    ast
    |> AST.find_all(&enum_into_empty_map?/1)
    |> Enum.map(fn {_, meta, args} ->
      build_diagnostic(file, AST.line(meta), arg_count(args))
    end)
  end

  defp enum_into_empty_map?({{:., _, [{:__aliases__, _, [:Enum]}, :into]}, _, args})
       when is_list(args) do
    case args do
      [_, {:%{}, _, []}] -> true
      [_, {:%{}, _, []}, _fun] -> true
      _ -> false
    end
  end

  defp enum_into_empty_map?(_), do: false

  defp arg_count([_, _]), do: 2
  defp arg_count([_, _, _]), do: 3
  defp arg_count(_), do: 0

  defp build_diagnostic(file, line, 2) do
    Diagnostic.info("6.91",
      title: "`Enum.into(coll, %{})` — use `Map.new(coll)`",
      message:
        "`Enum.into/2` with an empty map collectable is exactly `Map.new/1`. " <>
          "`Map.new` reads as the intent (\"build a map\") and skips the protocol " <>
          "dispatch through `Collectable`.",
      why:
        "`Enum.into/2` is the general form: insert each element of `coll` into a " <>
          "Collectable. When the collectable is the empty map literal, the call is " <>
          "indistinguishable from `Map.new(coll)` — but `Map.new/1` is more " <>
          "self-documenting and skips one layer of protocol dispatch on each " <>
          "element. Same pattern: prefer `MapSet.new/1` over `Enum.into(_, " <>
          "MapSet.new())`.",
      alternatives: [
        Fix.new(
          summary: "Replace with `Map.new/1`",
          detail: "Map.new(coll)\n# Same shape, idiomatic, faster.",
          applies_when: "Whenever the second argument is the empty `%{}` literal."
        )
      ],
      references: ["elixir-implementing/SKILL.md#2.2"],
      context: %{},
      file: file,
      line: line
    )
  end

  defp build_diagnostic(file, line, 3) do
    Diagnostic.info("6.91",
      title: "`Enum.into(coll, %{}, fun)` — use `Map.new(coll, fun)`",
      message:
        "`Enum.into/3` with an empty map collectable plus a transform function " <>
          "duplicates `Map.new/2`. The two-arg form is more direct, reads as the " <>
          "intent, and avoids the Collectable protocol dispatch.",
      why:
        "`Enum.into(coll, %{}, fun)` walks `coll`, calls `fun` on each element to " <>
          "produce `{key, value}`, and inserts via `Collectable.into/1`. " <>
          "`Map.new(coll, fun)` does the same work without going through the " <>
          "protocol on every element. Same pattern: prefer `MapSet.new/2` over " <>
          "`Enum.into(_, MapSet.new(), _)`.",
      alternatives: [
        Fix.new(
          summary: "Replace with `Map.new/2`",
          detail: "Map.new(coll, fn item -> {item.id, item.name} end)",
          applies_when: "Whenever the second argument is the empty `%{}` literal."
        )
      ],
      references: ["elixir-implementing/SKILL.md#2.2"],
      context: %{},
      file: file,
      line: line
    )
  end

  defp build_diagnostic(_file, _line, _), do: []
end
