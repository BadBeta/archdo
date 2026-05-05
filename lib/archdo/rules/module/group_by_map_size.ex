defmodule Archdo.Rules.Module.GroupByMapSize do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.66"

  @impl true
  def description,
    do: "`Enum.group_by |> Map.new(fn {k, v} -> {k, length(v)} end)` — use Enum.frequencies_by/2"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    Enum.map(AST.find_all(ast, &group_by_then_count?/1), fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta))
    end)
  end

  # `... |> Enum.group_by(...) |> Map.new(fn {k, v} -> {k, length(v)} end)`
  defp group_by_then_count?({:|>, _, [lhs, rhs]}) do
    enum_call?(lhs, :group_by) and counting_map_new?(rhs)
  end

  defp group_by_then_count?(_), do: false

  defp enum_call?({:|>, _, [_, inner]}, target), do: enum_call?(inner, target)

  defp enum_call?({{:., _, [{:__aliases__, _, [:Enum]}, fun]}, _, args}, target)
       when is_list(args),
       do: fun == target

  defp enum_call?(_, _), do: false

  # Match `Map.new(fn {k, v} -> {k, length(v)} end)` — pair-destructure
  # body that returns the same key with length of values.
  defp counting_map_new?(
         {{:., _, [{:__aliases__, _, [:Map]}, :new]}, _,
          [
            {:fn, _,
             [
               {:->, _,
                [
                  [{{kvar, _, _kctx}, {vvar, _, _vctx}}],
                  {{kvar2, _, _}, {:length, _, [{vvar2, _, _}]}}
                ]}
             ]}
          ]}
       ) do
    kvar == kvar2 and vvar == vvar2
  end

  defp counting_map_new?(_), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.66",
      title: "Group-by-then-count — use Enum.frequencies_by/2",
      message:
        "`Enum.group_by(items, key) |> Map.new(fn {k, v} -> {k, length(v)} end)` builds " <>
          "groups just to count them. `Enum.frequencies_by/2` does the count directly.",
      why:
        "`Enum.frequencies_by/2` was added for this exact case. It avoids materializing " <>
          "the full grouping list when only the counts matter — lower memory, single pass, " <>
          "shorter notation.",
      alternatives: [
        Fix.new(
          summary: "Replace with Enum.frequencies_by/2",
          detail: "Enum.frequencies_by(items, & &1.category)",
          applies_when: "When the only thing you do with the grouping is `length/1`."
        )
      ],
      references: ["elixir-implementing/SKILL.md#2.2"],
      context: %{},
      file: file,
      line: line
    )
  end
end
