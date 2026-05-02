defmodule Archdo.Rules.Module.EagerEvaluation do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.55"

  @impl true
  def description, do: "Over-eager evaluation — computing more than needed"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_eager_patterns(file, ast)
    end
  end

  defp find_eager_patterns(file, ast) do
    List.flatten([
      find_map_then_take(file, ast),
      find_map_then_hd(file, ast),
      find_to_list_then_filter(file, ast),
      find_map_then_count(file, ast),
      find_all_then_length(file, ast),
      find_map_then_find(file, ast)
    ])
  end

  # --- Enum.map |> Enum.take(n) → Enum.take then Enum.map, or Stream ---

  defp find_map_then_take(file, ast) do
    Enum.map(
      AST.find_all(ast, fn
        # list |> Enum.map(f) |> Enum.take(n)
        {:|>, _,
         [
           {:|>, _, [_, {{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, _}]},
           {{:., _, [{:__aliases__, _, [:Enum]}, :take]}, _, _}
         ]} ->
          true

        # Enum.take(Enum.map(list, f), n)
        {{:., _, [{:__aliases__, _, [:Enum]}, :take]}, _,
         [
           {{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, _} | _
         ]} ->
          true

        _ ->
          false
      end),
      fn {_, meta, _} ->
        build_diagnostic(file, AST.line(meta), :map_then_take)
      end
    )
  end

  # --- Enum.map |> hd → transform the first element only ---

  defp find_map_then_hd(file, ast) do
    Enum.map(
      AST.find_all(ast, fn
        # list |> Enum.map(f) |> hd()
        {:|>, _,
         [
           {:|>, _, [_, {{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, _}]},
           {:hd, _, _}
         ]} ->
          true

        # |> Enum.map(f) |> hd() (2-step pipe)
        {:|>, _,
         [
           {{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, _},
           {:hd, _, _}
         ]} ->
          true

        # hd(Enum.map(list, f))
        {:hd, _, [{{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, _}]} ->
          true

        _ ->
          false
      end),
      fn {_, meta, _} ->
        build_diagnostic(file, AST.line(meta), :map_then_hd)
      end
    )
  end

  # --- Enum.to_list(Stream...) |> Enum.filter → defeats lazy evaluation ---

  defp find_to_list_then_filter(file, ast) do
    Enum.map(
      AST.find_all(ast, fn
        # Stream.* |> Enum.to_list() |> Enum.filter/map/etc
        {:|>, _,
         [
           {:|>, _, [_, {{:., _, [{:__aliases__, _, [:Enum]}, :to_list]}, _, _}]},
           {{:., _, [{:__aliases__, _, [:Enum]}, func]}, _, _}
         ]}
        when func in [:filter, :map, :reject, :take, :find] ->
          true

        _ ->
          false
      end),
      fn {_, meta, _} ->
        build_diagnostic(file, AST.line(meta), :to_list_then_process)
      end
    )
  end

  # --- Enum.map |> Enum.count / length → Enum.count directly ---

  defp find_map_then_count(file, ast) do
    Enum.map(
      AST.find_all(ast, fn
        # list |> Enum.map(f) |> Enum.count()
        {:|>, _,
         [
           {:|>, _, [_, {{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, _}]},
           {{:., _, [{:__aliases__, _, [:Enum]}, :count]}, _, count_args}
         ]} ->
          # Enum.count() with no predicate — just counting mapped elements
          count_args in [nil, []]

        # list |> Enum.map(f) |> length()
        {:|>, _,
         [
           {:|>, _, [_, {{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, _}]},
           {:length, _, _}
         ]} ->
          true

        # list |> Enum.map(f) |> Enum.count()  (2-step pipe)
        {:|>, _,
         [
           {{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, _},
           {{:., _, [{:__aliases__, _, [:Enum]}, :count]}, _, count_args}
         ]} ->
          count_args in [nil, []]

        _ ->
          false
      end),
      fn {_, meta, _} ->
        build_diagnostic(file, AST.line(meta), :map_then_count)
      end
    )
  end

  # --- Repo.all |> length → Repo.aggregate(:count) ---

  defp find_all_then_length(file, ast) do
    Enum.map(
      AST.find_all(ast, fn
        # Repo.all(query) |> length()
        {:|>, _,
         [
           {{:., _, [{:__aliases__, _, aliases}, :all]}, _, _},
           {:length, _, _}
         ]} ->
          repo_module?(aliases)

        # Repo.all(query) |> Enum.count()
        {:|>, _,
         [
           {{:., _, [{:__aliases__, _, aliases}, :all]}, _, _},
           {{:., _, [{:__aliases__, _, [:Enum]}, :count]}, _, count_args}
         ]} ->
          repo_module?(aliases) and count_args in [nil, []]

        # length(Repo.all(query))
        {:length, _, [{{:., _, [{:__aliases__, _, aliases}, :all]}, _, _}]} ->
          repo_module?(aliases)

        _ ->
          false
      end),
      fn {_, meta, _} ->
        build_diagnostic(file, AST.line(meta), :all_then_length)
      end
    )
  end

  # --- Enum.map |> Enum.find → Enum.find_value ---

  defp find_map_then_find(file, ast) do
    Enum.map(
      AST.find_all(ast, fn
        # list |> Enum.map(f) |> Enum.find(g)
        {:|>, _,
         [
           {:|>, _, [_, {{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, _}]},
           {{:., _, [{:__aliases__, _, [:Enum]}, :find]}, _, _}
         ]} ->
          true

        {:|>, _,
         [
           {{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, _},
           {{:., _, [{:__aliases__, _, [:Enum]}, :find]}, _, _}
         ]} ->
          true

        _ ->
          false
      end),
      fn {_, meta, _} ->
        build_diagnostic(file, AST.line(meta), :map_then_find)
      end
    )
  end

  defp repo_module?(aliases) do
    case List.last(aliases) do
      :Repo -> true
      _ -> Enum.any?(aliases, &(&1 == :Repo))
    end
  end

  # --- Diagnostics ---

  defp build_diagnostic(file, line, :map_then_take) do
    Diagnostic.info("6.55",
      title: "Enum.map then Enum.take — transforms all, keeps few",
      message: "Enum.map processes every element before Enum.take discards most of them",
      why:
        "Enum.map eagerly transforms the entire collection, then Enum.take keeps only N. " <>
          "For a list of 10,000 elements where you take 5, 9,995 transformations are wasted.",
      alternatives: [
        Fix.new(
          summary: "Use Stream.map |> Enum.take or Enum.take |> Enum.map",
          detail:
            "`list |> Stream.map(&f/1) |> Enum.take(n)` — lazy, transforms only N elements.\n" <>
              "Or `list |> Enum.take(n) |> Enum.map(&f/1)` if the take condition is position-based.",
          applies_when: "The take count is much smaller than the collection size."
        )
      ],
      tags: [:perf],
      file: file,
      line: line
    )
  end

  defp build_diagnostic(file, line, :map_then_hd) do
    Diagnostic.info("6.55",
      title: "Enum.map then hd — transforms all to get first",
      message: "Enum.map processes every element but only the first is used",
      why: "Mapping the entire collection to take only the head wastes N-1 transformations.",
      alternatives: [
        Fix.new(
          summary: "Transform only the first element",
          detail:
            "`case list do [first | _] -> transform(first); [] -> nil end`\n" <>
              "Or `list |> List.first() |> then(&transform/1)` if nil is acceptable.",
          applies_when: "You only need the transformed first element."
        )
      ],
      tags: [:perf],
      file: file,
      line: line
    )
  end

  defp build_diagnostic(file, line, :to_list_then_process) do
    Diagnostic.info("6.55",
      title: "Enum.to_list then process — defeats lazy evaluation",
      message: "Converting a stream to a list before filtering/mapping materializes all elements",
      why:
        "Streams are lazy — they only compute elements as needed. Calling Enum.to_list " <>
          "materializes every element into memory, defeating the purpose of the stream. " <>
          "Chain Stream operations and terminate with a single Enum call.",
      alternatives: [
        Fix.new(
          summary: "Remove Enum.to_list and chain Stream/Enum directly",
          detail:
            "Instead of `stream |> Enum.to_list() |> Enum.filter(f)`, " <>
              "use `stream |> Stream.filter(f) |> Enum.to_list()` " <>
              "or just `stream |> Enum.filter(f)`.",
          applies_when: "A stream or lazy enumerable is materialized before further processing."
        )
      ],
      tags: [:perf],
      file: file,
      line: line
    )
  end

  defp build_diagnostic(file, line, :map_then_count) do
    Diagnostic.info("6.55",
      title: "Enum.map then count/length — map result discarded",
      message: "Mapping every element then counting discards all the mapped values",
      why:
        "The mapped values are immediately discarded — only the count matters. " <>
          "Enum.count/1 on the original list gives the same count without allocating " <>
          "an intermediate list.",
      alternatives: [
        Fix.new(
          summary: "Use Enum.count on the original or length/1",
          detail:
            "`list |> Enum.map(f) |> length()` → `length(list)` (map doesn't change count).\n" <>
              "If counting with a predicate: `Enum.count(list, &pred/1)`.",
          applies_when: "The map doesn't filter elements — count is the same before and after."
        )
      ],
      tags: [:perf],
      file: file,
      line: line
    )
  end

  defp build_diagnostic(file, line, :all_then_length) do
    Diagnostic.warning("6.55",
      title: "Repo.all then length — loads all rows to count them",
      message: "Repo.all fetches every row into memory just to count them",
      why:
        "Loading all rows from the database into Elixir to call length/1 or Enum.count/1 " <>
          "transfers potentially thousands of rows over the wire and into memory. " <>
          "A COUNT query does this in the database with zero data transfer.",
      alternatives: [
        Fix.new(
          summary: "Use Repo.aggregate(:count) or a count query",
          detail:
            "`Repo.all(query) |> length()` → `Repo.aggregate(query, :count)`\n" <>
              "Or `Repo.one(from q in query, select: count(q.id))`.",
          applies_when: "You only need the count, not the actual rows."
        )
      ],
      tags: [:perf],
      file: file,
      line: line
    )
  end

  defp build_diagnostic(file, line, :map_then_find) do
    Diagnostic.info("6.55",
      title: "Enum.map then Enum.find — transforms all to find one",
      message: "Enum.map transforms every element before Enum.find picks one",
      why:
        "Enum.map processes all N elements, then Enum.find stops at the first match. " <>
          "For a list of 10,000 where the match is at position 3, 9,997 maps are wasted.",
      alternatives: [
        Fix.new(
          summary: "Use Enum.find_value to combine find and transform",
          detail:
            "`list |> Enum.map(&f/1) |> Enum.find(&pred/1)` →\n" <>
              "`Enum.find_value(list, fn x -> if pred(f(x)), do: f(x) end)`\n" <>
              "Or use `Stream.map(&f/1) |> Enum.find(&pred/1)` for lazy evaluation.",
          applies_when: "You need to transform and then find."
        )
      ],
      tags: [:perf],
      file: file,
      line: line
    )
  end
end
