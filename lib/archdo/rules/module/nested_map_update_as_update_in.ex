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
    |> Enum.filter(&same_structure_inner_call?/1)
    |> Enum.map(fn outer -> build_diagnostic(file, AST.line(outer_meta(outer))) end)
  end

  # Outer must be Map.update/3,4 or Map.update!/3 — both have an update-fn
  # lambda whose parameter binds the value at the targeted key. Map.put has no
  # such lambda; any nested Map.put inside its value-arg operates on a
  # different structure (e.g., an Enum.reduce accumulator), so Map.put-outer
  # cannot be a same-structure nested update.
  defp outer_call?({{:., _, [{:__aliases__, _, [:Map]}, op]}, _, args})
       when op in [:update, :update!] and is_list(args),
       do: true

  defp outer_call?(_), do: false

  defp outer_meta({_, meta, _}), do: meta

  # Flag only when the inner Map.update/Map.put operates on the SAME structure
  # as the outer — i.e., its first argument is the variable bound by the
  # outer's update-fn lambda. This rejects FPs like
  # `Map.put(form_errors, :k, Enum.reduce(xs, %{}, fn _, acc -> Map.put(acc, ...) end))`
  # where `acc` is bound by Enum.reduce, not by the outer Map call.
  defp same_structure_inner_call?({_, _, args}) do
    case List.last(args) do
      {:fn, _, [{:->, _, [[{param, _, _}], body]}]} when is_atom(param) ->
        has_inner_call_on_var?(body, param)

      {:&, _, [body]} ->
        has_inner_call_on_capture_arg?(body)

      _ ->
        false
    end
  end

  defp has_inner_call_on_var?(body, param) do
    AST.contains?(body, fn
      {{:., _, [{:__aliases__, _, [:Map]}, op]}, _, [{var, _, _} | _]}
      when op in [:update, :update!, :put] and is_atom(var) and var == param ->
        true

      _ ->
        false
    end)
  end

  # Capture-form update-fn: `&Map.put(&1, key, value)`. The lambda parameter is
  # `&1` (AST `{:&, _, [1]}`); the inner Map call must take it as first arg.
  defp has_inner_call_on_capture_arg?(body) do
    AST.contains?(body, fn
      {{:., _, [{:__aliases__, _, [:Map]}, op]}, _, [{:&, _, [1]} | _]}
      when op in [:update, :update!, :put] ->
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
