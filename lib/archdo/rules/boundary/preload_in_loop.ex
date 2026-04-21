defmodule Archdo.Rules.Boundary.PreloadInLoop do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @repo_calls [:preload, :get, :get!, :one, :one!, :all]

  @impl true
  def id, do: "4.28"

  @impl true
  def description, do: "Repo query inside Enum.map/each/for — classic N+1 pattern"

  @impl true
  def analyze(file, ast, _opts) do
    cond do
      AST.test_file?(file) -> []
      true -> find_repo_in_loops(file, ast)
    end
  end

  defp find_repo_in_loops(file, ast) do
    enum_loop_results = find_enum_loop_repo_calls(file, ast)
    for_loop_results = find_for_loop_repo_calls(file, ast)

    enum_loop_results ++ for_loop_results
  end

  # Find Enum.map/each/flat_map with Repo calls inside the callback
  defp find_enum_loop_repo_calls(file, ast) do
    ast
    |> AST.find_all(fn
      {{:., _, [{:__aliases__, _, [:Enum]}, func]}, _, [_enumerable, callback]}
      when func in [:map, :each, :flat_map] ->
        contains_repo_call?(callback)

      _ ->
        false
    end)
    |> Enum.map(fn {{:., _, [{:__aliases__, _, [:Enum]}, func]}, meta, _} ->
      build_diagnostic(file, AST.line(meta), "Enum.#{func}")
    end)
  end

  # Find `for` comprehensions with Repo calls inside the body
  defp find_for_loop_repo_calls(file, ast) do
    ast
    |> AST.find_all(fn
      {:for, _, args} when is_list(args) ->
        body = Keyword.get(args, :do, nil) || find_do_block(args)
        body != nil and contains_repo_call?(body)

      _ ->
        false
    end)
    |> Enum.map(fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta), "for comprehension")
    end)
  end

  defp find_do_block(args) do
    Enum.find_value(args, fn
      [do: body] -> body
      {:do, body} -> body
      _ -> nil
    end)
  end

  defp contains_repo_call?(ast_node) do
    AST.contains?(ast_node, fn
      {{:., _, [{:__aliases__, _, aliases}, func]}, _, _} ->
        repo_module?(aliases) and func in @repo_calls

      _ ->
        false
    end)
  end

  defp repo_module?(aliases) do
    case List.last(aliases) do
      :Repo -> true
      _ -> Enum.any?(aliases, &(&1 == :Repo))
    end
  end

  defp build_diagnostic(file, line, loop_construct) do
    Diagnostic.warning("4.28",
      title: "N+1 query pattern",
      message: "Repo call inside #{loop_construct} — each iteration hits the database",
      why:
        "Calling Repo.preload, Repo.get, or Repo.one inside an Enum.map/each/for executes " <>
          "one database query per item in the collection. For 100 items, that's 100 queries " <>
          "instead of 1. This is the classic N+1 problem — performance degrades linearly with " <>
          "collection size and can bring down production databases under load.",
      alternatives: [
        Fix.new(
          summary: "Use Repo.preload on the entire collection before iterating",
          detail:
            "Replace the per-item preload with a batch preload: " <>
              "`posts = Repo.preload(posts, [:comments])` then `Enum.map(posts, ...)`. " <>
              "Ecto batches the preload into a single IN query.",
          applies_when: "You're preloading associations inside a loop."
        ),
        Fix.new(
          summary: "Use a join or preload in the original query",
          detail:
            "Add `preload: [:comments]` or a `join` to the query that fetches the collection. " <>
              "This loads everything in one or two queries before iteration starts.",
          applies_when: "You're fetching related data per item inside the loop."
        ),
        Fix.new(
          summary: "Batch the IDs and fetch in one query",
          detail:
            "Collect the IDs first with `Enum.map(items, & &1.related_id)`, then fetch " <>
              "all related records in one query: `Repo.all(from r in Related, where: r.id in ^ids)`. " <>
              "Build a lookup map and use it during iteration.",
          applies_when: "You're calling Repo.get per item to fetch a related record."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#4.28"],
      context: %{loop_construct: loop_construct},
      file: file,
      line: line
    )
  end
end
