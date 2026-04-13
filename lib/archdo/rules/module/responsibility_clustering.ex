defmodule Archdo.Rules.Module.ResponsibilityClustering do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  # Minimum public functions per cluster to count as a responsibility
  @min_cluster_size 2
  # Minimum number of independent clusters to flag
  @min_clusters 2
  # Minimum total public functions before we bother checking
  @min_public_fns 4

  @impl true
  def id, do: "6.12"

  @impl true
  def description,
    do: "Single Responsibility — module has independent function clusters suggesting multiple responsibilities"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      check_responsibility_clusters(file, ast)
    end
  end

  defp check_responsibility_clusters(file, ast) do
    all_fns = extract_all_functions(ast)
    public_fns = Enum.filter(all_fns, fn f -> f.visibility == :public end)

    if length(public_fns) < @min_public_fns do
      []
    else
      # Build intra-module call graph
      all_fn_names = MapSet.new(all_fns, & &1.key)
      call_graph = build_call_graph(all_fns, all_fn_names)

      # Find connected components among public functions via shared helpers
      clusters = find_clusters(public_fns, call_graph, all_fn_names)
      significant = Enum.filter(clusters, fn c -> length(c) >= @min_cluster_size end)

      if length(significant) >= @min_clusters do
        module_name = AST.extract_module_name(ast)
        [build_diagnostic(file, module_name, significant)]
      else
        []
      end
    end
  end

  # Extract all function definitions with name, arity, visibility, body
  defp extract_all_functions(ast) do
    {_, fns} =
      Macro.prewalk(ast, [], fn
        {:def, _meta, [{name, _, args} | rest]} = node, acc when is_atom(name) ->
          body = extract_body(rest)
          arity = length(args || [])
          {node, [%{key: {name, arity}, visibility: :public, body: body} | acc]}

        {:defp, _meta, [{name, _, args} | rest]} = node, acc when is_atom(name) ->
          body = extract_body(rest)
          arity = length(args || [])
          {node, [%{key: {name, arity}, visibility: :private, body: body} | acc]}

        node, acc ->
          {node, acc}
      end)

    # Deduplicate multi-clause functions by keeping the first body
    fns
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.key)
  end

  defp extract_body([[do: body]]), do: body
  defp extract_body([_args, [do: body]]), do: body
  defp extract_body(_), do: nil

  # Build map: function_key -> set of local functions it calls (directly)
  defp build_call_graph(all_fns, all_fn_names) do
    Enum.reduce(all_fns, %{}, fn f, graph ->
      called = find_local_calls(f.body, all_fn_names)
      Map.put(graph, f.key, called)
    end)
  end

  # Find all local function calls within a body that match known functions
  defp find_local_calls(nil, _known), do: MapSet.new()

  defp find_local_calls(body, known) do
    {_, calls} =
      Macro.prewalk(body, MapSet.new(), fn
        # Local call: foo(args...)
        {name, _meta, args} = node, acc
        when is_atom(name) and is_list(args) and name not in [:def, :defp, :defmodule, :do, :end,
             :if, :unless, :case, :cond, :with, :for, :fn, :receive, :try, :quote, :unquote,
             :raise, :throw, :import, :alias, :use, :require, :@, :__MODULE__] ->
          key = {name, length(args)}
          if MapSet.member?(known, key) do
            {node, MapSet.put(acc, key)}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    calls
  end

  # Find connected components among public functions.
  # Two public functions are connected if they share any reachable private helper.
  defp find_clusters(public_fns, call_graph, all_fn_names) do
    # For each public function, compute its reachable set (transitive closure)
    reachable_map =
      Map.new(public_fns, fn f ->
        {f.key, transitive_closure(f.key, call_graph, all_fn_names)}
      end)

    # Two public functions are in the same cluster if their reachable sets overlap
    pub_keys = Enum.map(public_fns, & &1.key)

    # Union-find via adjacency
    adjacency =
      for a <- pub_keys, b <- pub_keys, a < b, reduce: %{} do
        adj ->
          if MapSet.size(MapSet.intersection(reachable_map[a], reachable_map[b])) > 0 do
            adj
            |> Map.update(a, [b], &[b | &1])
            |> Map.update(b, [a], &[a | &1])
          else
            adj
          end
      end

    # BFS to find connected components
    find_components(pub_keys, adjacency)
  end

  defp transitive_closure(start, call_graph, all_fn_names) do
    do_closure([start], MapSet.new(), call_graph, all_fn_names)
  end

  defp do_closure([], visited, _graph, _known), do: visited

  defp do_closure([current | rest], visited, graph, known) do
    if MapSet.member?(visited, current) do
      do_closure(rest, visited, graph, known)
    else
      visited = MapSet.put(visited, current)
      neighbors = Map.get(graph, current, MapSet.new())
      new_to_visit = MapSet.to_list(MapSet.difference(neighbors, visited))
      do_closure(new_to_visit ++ rest, visited, graph, known)
    end
  end

  defp find_components(nodes, adjacency) do
    {components, _} =
      Enum.reduce(nodes, {[], MapSet.new()}, fn node, {comps, visited} ->
        if MapSet.member?(visited, node) do
          {comps, visited}
        else
          component = bfs(node, adjacency, MapSet.new())
          {[MapSet.to_list(component) | comps], MapSet.union(visited, component)}
        end
      end)

    Enum.reverse(components)
  end

  defp bfs(start, adjacency, visited) do
    do_bfs([start], visited, adjacency)
  end

  defp do_bfs([], visited, _adj), do: visited

  defp do_bfs([node | rest], visited, adj) do
    if MapSet.member?(visited, node) do
      do_bfs(rest, visited, adj)
    else
      visited = MapSet.put(visited, node)
      neighbors = Map.get(adj, node, [])
      do_bfs(neighbors ++ rest, visited, adj)
    end
  end

  defp build_diagnostic(file, module_name, clusters) do
    cluster_desc =
      clusters
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {fns, idx} ->
        names = Enum.map_join(fns, "/", fn {name, arity} -> "#{name}/#{arity}" end)
        "R#{idx}: {#{names}}"
      end)

    Diagnostic.warning("6.12",
      title: "Module has multiple independent responsibilities",
      message:
        "#{module_name} has #{length(clusters)} independent function clusters: #{cluster_desc}",
      why:
        "When a module's public functions form independent clusters — groups that never " <>
          "call each other or share private helpers — each cluster represents a separate " <>
          "reason to change. Changes to one responsibility risk breaking unrelated code " <>
          "in the same file. Splitting into focused modules makes each one easier to " <>
          "understand, test, and modify independently.",
      alternatives: [
        Fix.new(
          summary: "Extract each cluster into its own module",
          detail:
            "Move each function cluster and its private helpers into a dedicated module. " <>
              "The original module can become a facade with `defdelegate` calls if callers " <>
              "need a single entry point.",
          applies_when: "The clusters represent genuinely independent concerns."
        ),
        Fix.new(
          summary: "Add shared helpers to unify the clusters",
          detail:
            "If the clusters should be one responsibility but grew apart, add shared " <>
              "private functions that both clusters use. This makes the module cohesive again.",
          applies_when: "The independence is accidental, not architectural."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.12"],
      context: %{
        module: module_name,
        cluster_count: length(clusters),
        clusters:
          Enum.map(clusters, fn fns ->
            Enum.map(fns, fn {name, arity} -> "#{name}/#{arity}" end)
          end)
      },
      file: file,
      line: 1
    )
  end
end
