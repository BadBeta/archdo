defmodule Archdo.Rules.Module.InefficientFilter do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.57"

  @impl true
  def description,
    do: "Inefficient filter — Repo read followed by Enum.filter that could be DB-side"

  # Repo read functions that return a list (or stream of records) and
  # whose post-filter could often move into a `where` clause.
  @list_returning_repo_calls [:all, :preload, :stream, :stream_preload]

  @impl true
  def analyze(file, ast, _opts) do
    cond do
      AST.test_file?(file) -> []
      AST.has_marker?(ast, :archdo_intentional_filter) -> []
      true -> find_inefficient_filters(file, ast)
    end
  end

  defp find_inefficient_filters(file, ast) do
    Enum.map(AST.find_all(ast, &inefficient_filter_pipe?/1), fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta))
    end)
  end

  # Pipeline shape: `<Repo.list-returning-call>(...) |> Enum.filter(<inline-pred>)`
  defp inefficient_filter_pipe?({:|>, _, [lhs, rhs]}) do
    repo_list_returning_call?(lhs) and inline_filter?(rhs)
  end

  defp inefficient_filter_pipe?(_), do: false

  # Match `Repo.all(...)`, `Repo.preload(...)`, etc. — possibly nested
  # behind further pipe steps on the LHS. Walk through any pipe
  # ancestors so `Repo.all(User) |> Repo.preload(:posts) |> Enum.filter(...)`
  # still triggers when the outermost LHS is a list-returning Repo call.
  defp repo_list_returning_call?({:|>, _, [_, rhs]}), do: repo_list_returning_call?(rhs)

  defp repo_list_returning_call?({{:., _, [{:__aliases__, _, mod_parts}, fun]}, _, _})
       when is_atom(fun) do
    last_segment_repo?(mod_parts) and fun in @list_returning_repo_calls
  end

  defp repo_list_returning_call?(_), do: false

  defp last_segment_repo?(parts) when is_list(parts), do: List.last(parts) == :Repo
  defp last_segment_repo?(_), do: false

  # Right-hand side: `Enum.filter(<arg>)`. The arg shape determines
  # whether the predicate is "DB-translatable" (inline `&(&1.field)`
  # or a small fn) vs an opaque function reference.
  defp inline_filter?({{:., _, [{:__aliases__, _, [:Enum]}, :filter]}, _, [arg]}),
    do: inline_predicate?(arg)

  defp inline_filter?(_), do: false

  # `&MyApp.fun/1` — remote function reference; can't introspect, skip.
  # AST: `{:&, _, [{:/, _, [{{:., _, [_, _]}, _, []}, arity]}]}`
  defp inline_predicate?({:&, _, [{:/, _, [{{:., _, _}, _, _}, _arity]}]}), do: false

  # `&local_fn/1` — local function reference, also skip.
  defp inline_predicate?({:&, _, [{:/, _, [{name, _, _ctx}, _arity]}]})
       when is_atom(name),
       do: false

  # `&(&1.field)` or any inline capture body — DB-translatable in many
  # cases. Fire.
  defp inline_predicate?({:&, _, _}), do: true

  # `fn x -> ... end` — anonymous function with explicit body. Fire
  # (the body could be inspected later for translatability; for v1
  # we trust the author to wrap genuinely-Elixir-side filters with a
  # remote function reference instead).
  defp inline_predicate?({:fn, _, _}), do: true

  defp inline_predicate?(_), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.57",
      title: "Inefficient filter (Repo read |> Enum.filter)",
      message:
        "A Repo read is followed by Enum.filter — the filter could often move into a " <>
          "`where` clause and reduce wire and memory cost.",
      why:
        "Fetching all rows then filtering in Elixir uses more DB IO, more network, and " <>
          "more memory than letting Postgres apply the predicate. The cost grows with the " <>
          "table size; for tables that scale with users / events / objects, the same code " <>
          "that's fine in dev silently degrades in production.",
      alternatives: [
        Fix.new(
          summary: "Move the predicate into the Ecto query",
          detail:
            "Replace `Repo.all(Q) |> Enum.filter(&(&1.field == val))` with " <>
              "`from(q in Q, where: q.field == ^val) |> Repo.all/1`. The predicate runs in " <>
              "the database; only matching rows cross the wire.",
          applies_when: "When the predicate is a simple field comparison or boolean."
        ),
        Fix.new(
          summary: "Mark intentional Elixir-side filtering",
          detail:
            "If the predicate genuinely cannot be expressed in SQL (calls a function with " <>
              "side effects, depends on Elixir-only data), wrap it in a remote function " <>
              "reference (`&MyApp.eligible?/1`) — the rule won't fire for function references.",
          applies_when: "When the predicate truly belongs in Elixir."
        )
      ],
      references: ["GUIDE.md#6.57"],
      context: %{},
      file: file,
      line: line
    )
  end
end
