defmodule Archdo.Rules.Module.NestedMapUpdateAsUpdateIn do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.98"

  @impl true
  def description, do: "Nested `Map.update` / `Map.put` chain — `update_in` / `put_in` is cleaner"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_nested_chains(file, ast)
    end
  end

  defp find_nested_chains(file, ast) do
    ast
    |> AST.find_all(&outer_call?/1)
    |> Enum.filter(&contains_inner_call?/1)
    |> Enum.map(fn outer -> build_diagnostic(file, AST.line(outer_meta(outer))) end)
  end

  # Outer must be a top-level Map.update/3,4 or Map.put/3
  defp outer_call?({{:., _, [{:__aliases__, _, [:Map]}, op]}, _, args})
       when op in [:update, :put] and is_list(args),
       do: true

  defp outer_call?(_), do: false

  defp outer_meta({_, meta, _}), do: meta

  defp contains_inner_call?({_, _, args}) do
    args
    |> Enum.drop(1)
    |> Enum.any?(&has_nested_map_call?/1)
  end

  # Walk the subtree looking for ANOTHER Map.update / Map.put. The outer
  # node itself is the entry point, so skip the very first match by
  # excluding the original node identity via meta — but find_all's prewalk
  # naturally enters children only after the parent, so checking children
  # directly works.
  defp has_nested_map_call?(ast) do
    AST.contains?(ast, fn
      {{:., _, [{:__aliases__, _, [:Map]}, op]}, _, args}
      when op in [:update, :put] and is_list(args) ->
        true

      _ ->
        false
    end)
  end

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.98",
      title: "Nested `Map.update` / `Map.put` — `update_in` is cleaner",
      message:
        "A `Map.update` / `Map.put` whose value/update-fn contains another " <>
          "`Map.update` / `Map.put` is reaching into nested structure — that's " <>
          "what `update_in` and `put_in` are for.",
      why:
        "Two levels of nested `Map.update` / `Map.put` is the threshold past " <>
          "which an Access path is more readable: " <>
          "`update_in(state, [:counts, :total], &(&1 + 1))` says exactly what " <>
          "the code does, in one line, and composes with deeper structures " <>
          "without growing the nesting. The nested-lambda form is harder to " <>
          "read, harder to refactor, and obscures the path being traversed.",
      alternatives: [
        Fix.new(
          summary: "Use `update_in` / `put_in` with a path",
          detail:
            "Express the nested update as an Access path. For domain structs " <>
              "that need deep updates, either implement `Access` (`@behaviour " <>
              "Access`) or split the operation across helpers.",
          example: """
          ```elixir
          # before
          Map.update(state, :counts, %{}, fn counts ->
            Map.put(counts, :total, 1)
          end)

          # after
          put_in(state, [:counts, :total], 1)
          ```
          """,
          applies_when: "The path is statically known and 2-4 levels deep."
        ),
        Fix.new(
          summary: "Reach for Pathex / Focus",
          detail:
            "If paths are dynamic or 5+ levels deep, a focused-lens library " <>
              "is more composable than `update_in`.",
          applies_when: "The path is computed at runtime or extremely deep."
        )
      ],
      file: file,
      line: line
    )
  end
end
