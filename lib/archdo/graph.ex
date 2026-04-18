defmodule Archdo.Graph do
  @moduledoc false

  alias Archdo.AST

  @type dep_type :: :alias | :import | :use | :call
  @type edge :: %{
          source: String.t(),
          target: String.t(),
          type: dep_type(),
          file: String.t(),
          line: non_neg_integer()
        }

  @type t :: %__MODULE__{
          modules: MapSet.t(String.t()),
          edges: [edge()],
          edges_by_source: %{String.t() => [edge()]},
          modules_by_file: %{String.t() => [String.t()]}
        }

  defstruct modules: MapSet.new(),
            edges: [],
            edges_by_source: %{},
            modules_by_file: %{}

  @doc """
  Build a module dependency graph from a list of {file, ast} tuples.
  """
  @spec build([{String.t(), Macro.t()}]) :: t()
  def build(file_asts) do
    Enum.reduce(file_asts, %__MODULE__{}, fn {file, ast}, graph ->
      analyze_file(graph, file, ast)
    end)
  end

  @doc """
  Get all direct dependencies of a module.
  """
  @spec dependencies(t(), String.t()) :: [edge()]
  def dependencies(%__MODULE__{edges_by_source: by_source}, module_name) do
    Map.get(by_source, module_name, [])
  end

  @doc """
  Get all edges that point TO a given module (reverse lookup).
  """
  @spec dependencies_of(t(), String.t()) :: [edge()]
  def dependencies_of(%__MODULE__{edges: edges}, module_name) do
    Enum.filter(edges, &(&1.target == module_name))
  end

  @doc """
  Find all cycles in the graph between the given set of top-level modules (contexts).
  Returns a list of cycles, where each cycle is a list of module names.
  """
  @spec find_cycles(t(), [module()]) :: [[String.t()]]
  def find_cycles(%__MODULE__{} = graph, root_modules) do
    # Build adjacency map between root modules only
    adjacency =
      Enum.reduce(root_modules, %{}, fn mod, acc ->
        mod_str = AST.module_name(mod)

        targets =
          graph
          |> dependencies(mod_str)
          |> Enum.map(& &1.target)
          |> Enum.filter(fn target ->
            Enum.any?(root_modules, fn rm ->
              rm_str = AST.module_name(rm)
              rm_str != mod_str and (target == rm_str or String.starts_with?(target, rm_str <> "."))
            end)
          end)
          |> Enum.map(fn target ->
            Enum.find(root_modules, fn rm ->
              rm_str = AST.module_name(rm)
              target == rm_str or String.starts_with?(target, rm_str <> ".")
            end)
            |> AST.module_name()
          end)
          |> Enum.uniq()

        Map.put(acc, mod_str, targets)
      end)

    # DFS cycle detection
    detect_cycles_dfs(adjacency, Enum.map(root_modules, &AST.module_name/1))
  end

  @doc """
  Get all modules in a given namespace (prefix).
  """
  @spec modules_in_namespace(t(), String.t() | atom()) :: [String.t()]
  def modules_in_namespace(%__MODULE__{modules: modules}, prefix) do
    prefix_str = AST.module_name(prefix)

    modules
    |> MapSet.to_list()
    |> Enum.filter(fn mod ->
      mod == prefix_str or String.starts_with?(mod, prefix_str <> ".")
    end)
  end

  # --- Building the graph ---

  defp analyze_file(graph, file, ast) do
    modules = extract_module_names(ast)
    edges = extract_edges(ast, file)

    %{
      graph
      | modules: Enum.reduce(modules, graph.modules, &MapSet.put(&2, &1)),
        edges: edges ++ graph.edges,
        edges_by_source:
          Enum.reduce(edges, graph.edges_by_source, fn edge, acc ->
            Map.update(acc, edge.source, [edge], &[edge | &1])
          end),
        modules_by_file:
          Map.put(graph.modules_by_file, file, modules)
    }
  end

  defp extract_module_names(ast) do
    {_, names} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [{:__aliases__, _, aliases} | _]} = node, acc ->
          case AST.safe_concat(aliases) do
            nil -> {node, acc}
            mod -> {node, [AST.module_name(mod) | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(names)
  end

  defp extract_edges(ast, file) do
    {_, {_current_module, edges}} =
      Macro.prewalk(ast, {nil, []}, fn
        # Track current module
        {:defmodule, _, [{:__aliases__, _, aliases} | _]} = node, {_mod, edges}
        when is_atom(hd(aliases)) ->
          {node, {safe_concat(aliases), edges}}

        # alias MyApp.Foo
        {:alias, meta, [{:__aliases__, _, aliases} | _]} = node, {mod, edges} when mod != nil ->
          case safe_concat(aliases) do
            nil -> {node, {mod, edges}}
            target ->
              edge = %{source: mod, target: target, type: :alias, file: file, line: line(meta)}
              {node, {mod, [edge | edges]}}
          end

        # import MyApp.Foo
        {:import, meta, [{:__aliases__, _, aliases} | _]} = node, {mod, edges} when mod != nil ->
          case safe_concat(aliases) do
            nil -> {node, {mod, edges}}
            target ->
              edge = %{source: mod, target: target, type: :import, file: file, line: line(meta)}
              {node, {mod, [edge | edges]}}
          end

        # use MyApp.Foo
        {:use, meta, [{:__aliases__, _, aliases} | _]} = node, {mod, edges} when mod != nil ->
          case safe_concat(aliases) do
            nil -> {node, {mod, edges}}
            target ->
              edge = %{source: mod, target: target, type: :use, file: file, line: line(meta)}
              {node, {mod, [edge | edges]}}
          end

        # Remote call: MyApp.Foo.bar(...)
        {{:., meta, [{:__aliases__, _, aliases}, _func]}, _, _args} = node, {mod, edges}
        when mod != nil ->
          case safe_concat(aliases) do
            nil -> {node, {mod, edges}}
            target ->
              edge = %{source: mod, target: target, type: :call, file: file, line: line(meta)}
              {node, {mod, [edge | edges]}}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(edges)
  end

  # Safely concat module aliases, returning nil for dynamic references
  # (e.g. __MODULE__.Foo contains a non-atom element).
  defp safe_concat(aliases) do
    if Enum.all?(aliases, &is_atom/1) do
      AST.module_name(Module.concat(aliases))
    else
      nil
    end
  end

  defp line(meta), do: AST.line(meta)

  # --- Cycle detection ---

  # DFS state accumulated through the traversal
  defp detect_cycles_dfs(adjacency, nodes) do
    state = %{visited: MapSet.new(), in_stack: MapSet.new(), cycles: []}

    result =
      Enum.reduce(nodes, state, fn node, acc ->
        if MapSet.member?(acc.visited, node) do
          acc
        else
          dfs_visit(node, adjacency, acc, [node])
        end
      end)

    result.cycles
    |> Enum.uniq_by(&MapSet.new/1)
  end

  defp dfs_visit(node, adjacency, state, path) do
    state = %{state | visited: MapSet.put(state.visited, node), in_stack: MapSet.put(state.in_stack, node)}

    state =
      Enum.reduce(Map.get(adjacency, node, []), state, fn neighbor, acc ->
        cond do
          MapSet.member?(acc.in_stack, neighbor) ->
            ordered = Enum.reverse(path)
            cycle_start = Enum.find_index(ordered, &(&1 == neighbor))

            case cycle_start do
              nil -> acc
              idx ->
                cycle = Enum.slice(ordered, idx..-1//1) ++ [neighbor]
                %{acc | cycles: [cycle | acc.cycles]}
            end

          not MapSet.member?(acc.visited, neighbor) ->
            dfs_visit(neighbor, adjacency, acc, [neighbor | path])

          true ->
            acc
        end
      end)

    %{state | in_stack: MapSet.delete(state.in_stack, node)}
  end
end
