defmodule Archdo.Graph do
  @moduledoc false

  alias Archdo.AST

  @type dep_type :: :alias | :import | :use | :call

  # Edge-type names — single source of truth for the four atoms.
  @call_type :call
  @alias_type :alias
  @registry_type :registry
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
  Predicate — is the edge's type `kind`?
  Centralizes edge-type tagging so consumers don't carry the literal
  atom (`:call`, `:alias`, `:registry`) at every filter site.
  """
  @spec edge_of_type?(edge(), dep_type()) :: boolean()
  def edge_of_type?(edge, kind) when is_atom(kind), do: edge.type == kind

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
      Map.new(root_modules, &adjacency_entry(&1, graph, root_modules))

    # DFS cycle detection
    detect_cycles_dfs(adjacency, Enum.map(root_modules, &AST.module_name/1))
  end

  defp adjacency_entry(mod, graph, root_modules) do
    mod_str = AST.module_name(mod)

    resolved =
      for dep <- dependencies(graph, mod_str),
          target_in_root?(dep.target, mod_str, root_modules),
          do: resolve_target_to_root(dep.target, root_modules)

    targets = Enum.uniq(resolved)

    {mod_str, targets}
  end

  defp target_in_root?(target, mod_str, root_modules) do
    Enum.any?(root_modules, fn rm ->
      rm_str = AST.module_name(rm)
      rm_str != mod_str and AST.module_under_namespace?(target, rm_str)
    end)
  end

  defp resolve_target_to_root(target, root_modules) do
    AST.module_name(
      Enum.find(root_modules, fn rm ->
        AST.module_under_namespace?(target, AST.module_name(rm))
      end)
    )
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

  # M-Aux1: collect module attributes whose value is a list of module
  # aliases (per host module), then emit `:registry` edges from the
  # host module to each listed module wherever the attribute is read.
  #
  # An attribute read is `{:@, _, [{name, _, args}]}` where `args` is
  # nil (or atom context). The attribute write has `args = [value]`.
  # Reads anywhere in the module body produce edges — covering both
  # direct iteration (`Enum.each(@rules, ...)`, `for x <- @rules`) and
  # indirect dispatch through accessor functions (`def rules, do:
  # @rules`) or helper plumbing (`filter_rules(@rules, opts)`).
  #
  # The pattern shows up in dispatch tables (`@rules [Foo, Bar]`,
  # `@plugins [...]`), making the listed modules transitively
  # reachable for CE-30 closure when they otherwise look orphaned.
  defp extract_registry_edges(ast, file) do
    {_, {_current, edges, _registries}} =
      Macro.prewalk(ast, {nil, [], %{}}, fn
        # Track current module + its alias-list registries.
        {:defmodule, _, [{:__aliases__, _, aliases} | _]} = node, {_mod, edges, _regs}
        when is_atom(hd(aliases)) ->
          mod = safe_concat(aliases)
          {node, {mod, edges, alias_list_registries(node)}}

        # Attribute READ: `{:@, _, [{name, _, nil_or_atom_context}]}`.
        # A WRITE has `{name, _, [value]}` (args is a list); skip those.
        {:@, meta, [{name, _, args}]} = node, {mod, edges, regs}
        when is_atom(name) and (args == nil or is_atom(args)) and mod != nil ->
          attr_read_edges(Map.get(regs, name), node, mod, edges, regs, file, meta)

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(edges)
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # whether the registry attribute is known (nil means write-only).
  defp attr_read_edges(nil, node, mod, edges, regs, _file, _meta), do: {node, {mod, edges, regs}}

  defp attr_read_edges(targets, node, mod, edges, regs, file, meta) do
    new_edges =
      Enum.map(targets, fn target ->
        %{source: mod, target: target, type: @registry_type, file: file, line: AST.line(meta)}
      end)

    {node, {mod, new_edges ++ edges, regs}}
  end

  # Pre-scan a module body for `@attr [Mod, Mod, ...]` writes; return
  # %{attr_name => [target_module_string, ...]} where the value is a
  # non-empty list of module aliases.
  #
  # Single-segment aliases (`Mockability` after `alias Foo.Bar.Mockability`)
  # are expanded via the module's alias table so that registry edges
  # name the full module path, not the short form.
  defp alias_list_registries({:defmodule, _, [_alias, kw]}) when is_list(kw) do
    body = AST.do_body(kw)
    alias_table = collect_alias_table(body)

    {_, regs} =
      Macro.prewalk(body, %{}, fn
        # Write: @attr_name <list>. Args is a 1-element list containing
        # the value. Under literal_encoder the list itself is wrapped.
        {:@, _, [{name, _, [value]}]} = node, acc when is_atom(name) ->
          case alias_list_targets(value, alias_table) do
            [] -> {node, acc}
            targets -> {node, Map.put(acc, name, targets)}
          end

        node, acc ->
          {node, acc}
      end)

    regs
  end

  defp alias_list_registries(_), do: %{}

  # Walk the body for `alias Foo.Bar.Baz` (and `alias Foo.{Bar, Baz}`)
  # statements; return %{short_name_atom => "Foo.Bar.Baz"} for
  # short-name resolution.
  defp collect_alias_table(body) do
    {_, table} =
      Macro.prewalk(body || [], %{}, fn
        # alias Foo.Bar.Baz  →  short = :Baz, full = "Foo.Bar.Baz"
        {:alias, _, [{:__aliases__, _, parts}]} = node, acc when is_list(parts) ->
          {node, add_alias(acc, parts)}

        # alias Foo.Bar.Baz, as: Quux
        {:alias, _, [{:__aliases__, _, parts}, [{:as, {:__aliases__, _, [as_name]}}]]} = node, acc
        when is_list(parts) and is_atom(as_name) ->
          full = safe_concat(parts)

          case full do
            nil -> {node, acc}
            f -> {node, Map.put(acc, as_name, f)}
          end

        # alias Foo.{Bar, Baz} — expand each
        {:alias, _, [{{:., _, [{:__aliases__, _, prefix_parts}, :{}]}, _, suffixes}]} = node, acc
        when is_list(prefix_parts) and is_list(suffixes) ->
          new_acc =
            Enum.reduce(suffixes, acc, fn
              {:__aliases__, _, suffix_parts}, inner_acc when is_list(suffix_parts) ->
                add_alias(inner_acc, Enum.concat(prefix_parts, suffix_parts))

              _, inner_acc ->
                inner_acc
            end)

          {node, new_acc}

        node, acc ->
          {node, acc}
      end)

    table
  end

  defp add_alias(table, [_ | _] = parts) do
    case safe_concat(parts) do
      nil -> table
      full -> Map.put(table, List.last(parts), full)
    end
  end

  defp add_alias(table, _), do: table

  # Extract module-alias targets from a literal list value. Returns []
  # if the value isn't a list of aliases. Single-segment names are
  # resolved via the module's alias table.
  defp alias_list_targets({:__block__, _, [list]}, alias_table) when is_list(list),
    do: alias_list_targets(list, alias_table)

  defp alias_list_targets(list, alias_table) when is_list(list) do
    reduced =
      Enum.reduce_while(list, [], fn elem, acc ->
        case alias_target(elem, alias_table) do
          nil -> {:halt, []}
          target -> {:cont, [target | acc]}
        end
      end)

    Enum.reverse(reduced)
  end

  defp alias_list_targets(_, _), do: []

  defp alias_target({:__aliases__, _, [single]}, alias_table) when is_atom(single) do
    # Single-segment alias: try the alias table first, fall back to bare name
    Map.get(alias_table, single, Atom.to_string(single))
  end

  defp alias_target({:__aliases__, _, parts}, _alias_table) when is_list(parts) do
    safe_concat(parts)
  end

  defp alias_target(_, _), do: nil

  defp analyze_file(graph, file, ast) do
    modules = extract_module_names(ast)
    edges = extract_edges(ast, file) ++ extract_registry_edges(ast, file)

    %{
      graph
      | modules: MapSet.union(graph.modules, MapSet.new(modules)),
        edges: edges ++ graph.edges,
        edges_by_source:
          Enum.reduce(edges, graph.edges_by_source, fn edge, acc ->
            Map.update(acc, edge.source, [edge], &[edge | &1])
          end),
        modules_by_file: Map.put(graph.modules_by_file, file, modules)
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

  # State threaded through the prewalk:
  #   :module       — fully-qualified name of the current `defmodule`, or nil
  #   :alias_table  — %{single_segment_atom => fully_qualified_module_name}
  #                   built up as we encounter `alias` declarations. Used to
  #                   resolve short-form references in call sites, `use`,
  #                   `import`, and `apply/3`. Without this, a call
  #                   `Runner.foo()` after `alias Archdo.Runner` resolves
  #                   to bare `"Runner"` — no module by that name —
  #                   creating a dangling edge that breaks reachability
  #                   from anchors.
  defp extract_edges(ast, file) do
    initial = %{module: nil, alias_table: %{}}

    {_, {_state, edges}} =
      Macro.prewalk(ast, {initial, []}, fn
        # Enter defmodule — reset state to the new module's scope.
        {:defmodule, _, [{:__aliases__, _, aliases} | _]} = node, {_state, edges}
        when is_atom(hd(aliases)) ->
          {node, {%{module: safe_concat(aliases), alias_table: %{}}, edges}}

        # alias Foo.Bar — single multi-segment alias.
        # Adds edge AND populates alias_table[:Bar => "Foo.Bar"].
        {:alias, meta, [{:__aliases__, _, parts}]} = node, {state, edges} ->
          handle_simple_alias(parts, nil, state, edges, node, file, meta)

        # alias Foo.Bar, as: Quux — alias with renamed binding (bare-atom
        # keyword key, e.g. when AST was parsed without literal_encoder).
        {:alias, meta, [{:__aliases__, _, parts}, [{:as, {:__aliases__, _, [as_name]}}]]} = node,
        {state, edges}
        when is_atom(as_name) ->
          handle_simple_alias(parts, as_name, state, edges, node, file, meta)

        # alias Foo.Bar, as: Quux — same form, but the keyword key is
        # wrapped as {:__block__, _, [:as]} because the AST was parsed
        # with literal_encoder (Archdo's default). Both shapes occur in
        # the wild — keep both clauses for robustness.
        {:alias, meta,
         [
           {:__aliases__, _, parts},
           [{{:__block__, _, [:as]}, {:__aliases__, _, [as_name]}}]
         ]} = node,
        {state, edges}
        when is_atom(as_name) ->
          handle_simple_alias(parts, as_name, state, edges, node, file, meta)

        # alias Foo.{Bar, Baz} — multi-alias form. Each suffix gets an
        # edge and an alias_table entry. Without this clause, callers
        # like `alias Archdo.{Runner, Rules}` produce zero edges — a
        # massive blind spot in the previous extractor.
        {:alias, meta, [{{:., _, [{:__aliases__, _, prefix_parts}, :{}]}, _, suffixes}]} = node,
        {state, edges} ->
          handle_multi_alias(prefix_parts, suffixes, state, edges, node, file, meta)

        # import Foo.Bar — emits an edge. Imports don't bind a short
        # form, so no alias_table update.
        {:import, meta, [{:__aliases__, _, parts} | _]} = node, {state, edges} ->
          handle_resolved_edge(parts, :import, state, edges, node, file, meta)

        # use Foo.Bar
        {:use, meta, [{:__aliases__, _, parts} | _]} = node, {state, edges} ->
          handle_resolved_edge(parts, :use, state, edges, node, file, meta)

        # Remote call: Foo.bar() / Foo.Bar.baz(). Single-segment aliases
        # are resolved via the alias table. Multi-segment go through
        # safe_concat/1. Without alias-table resolution, a call to
        # `Runner.foo()` after `alias Archdo.Runner` would create a
        # dangling edge to bare "Runner".
        {{:., meta, [{:__aliases__, _, parts}, _func]}, _, _args} = node, {state, edges} ->
          handle_resolved_edge(parts, @call_type, state, edges, node, file, meta)

        # apply(Foo, :func, args) with literal module alias.
        {:apply, meta, [{:__aliases__, _, parts}, _fn_atom, _args]} = node, {state, edges} ->
          handle_resolved_edge(parts, :dynamic_dispatch, state, edges, node, file, meta)

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(edges)
  end

  defp handle_simple_alias(parts, as_name, state, edges, node, file, meta) do
    case safe_concat(parts) do
      nil ->
        {node, {state, edges}}

      target ->
        edge = %{
          source: state.module,
          target: target,
          type: @alias_type,
          file: file,
          line: AST.line(meta)
        }

        binding = as_name || List.last(parts)
        new_state = put_in(state.alias_table[binding], target)
        {node, {new_state, [edge | edges]}}
    end
  end

  defp handle_multi_alias(prefix_parts, suffixes, state, edges, node, file, meta) do
    {new_edges, new_table} =
      Enum.reduce(suffixes, {edges, state.alias_table}, fn suffix, acc ->
        accumulate_multi_alias(suffix, acc, prefix_parts, state.module, file, meta)
      end)

    {node, {%{state | alias_table: new_table}, new_edges}}
  end

  defp accumulate_multi_alias(
         {:__aliases__, _, suffix_parts},
         {acc_edges, acc_table},
         prefix_parts,
         source,
         file,
         meta
       ) do
    case safe_concat(prefix_parts ++ suffix_parts) do
      nil ->
        {acc_edges, acc_table}

      target ->
        edge = %{
          source: source,
          target: target,
          type: @alias_type,
          file: file,
          line: AST.line(meta)
        }

        {[edge | acc_edges], Map.put(acc_table, List.last(suffix_parts), target)}
    end
  end

  defp accumulate_multi_alias(_, acc, _prefix, _source, _file, _meta), do: acc

  # Resolve `parts` via the alias table and emit an edge of the given
  # `type`. Used for `import`, `use`, remote calls, and `apply/3` —
  # all four resolve short-form aliases the same way and emit the
  # same edge shape, only the `type` differs.
  defp handle_resolved_edge(parts, type, state, edges, node, file, meta) do
    case resolve_alias(parts, state.alias_table) do
      nil ->
        {node, {state, edges}}

      target ->
        edge = %{
          source: state.module,
          target: target,
          type: type,
          file: file,
          line: AST.line(meta)
        }

        {node, {state, [edge | edges]}}
    end
  end

  # Resolve an alias-parts list to a fully-qualified module name. For
  # single-segment short forms (e.g. [:Runner]), look up in the alias
  # table; fall back to the bare segment name when no binding exists.
  # Multi-segment forms go through safe_concat/1.
  defp resolve_alias([single], alias_table) when is_atom(single) do
    case Map.fetch(alias_table, single) do
      {:ok, full} -> full
      :error -> Atom.to_string(single)
    end
  end

  defp resolve_alias(parts, _alias_table) when is_list(parts) do
    safe_concat(parts)
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

    Enum.uniq_by(result.cycles, &MapSet.new/1)
  end

  defp dfs_visit(node, adjacency, state, path) do
    state = %{
      state
      | visited: MapSet.put(state.visited, node),
        in_stack: MapSet.put(state.in_stack, node)
    }

    state =
      Enum.reduce(Map.get(adjacency, node, []), state, fn neighbor, acc ->
        visit_neighbor(neighbor, adjacency, acc, path)
      end)

    %{state | in_stack: MapSet.delete(state.in_stack, node)}
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # the neighbor's classification (in-stack means cycle, unvisited
  # means recurse, otherwise no-op). Tagged via a small classifier
  # to keep each clause shallow.
  defp visit_neighbor(neighbor, adjacency, acc, path) do
    handle_neighbor(neighbor_state(neighbor, acc), neighbor, adjacency, acc, path)
  end

  defp neighbor_state(neighbor, acc) do
    cond do
      MapSet.member?(acc.in_stack, neighbor) -> :cycle_back_edge
      not MapSet.member?(acc.visited, neighbor) -> :unvisited
      true -> :already_visited
    end
  end

  defp handle_neighbor(:cycle_back_edge, neighbor, _adjacency, acc, path) do
    record_cycle(
      Enum.find_index(Enum.reverse(path), &(&1 == neighbor)),
      Enum.reverse(path),
      neighbor,
      acc
    )
  end

  defp handle_neighbor(:unvisited, neighbor, adjacency, acc, path) do
    dfs_visit(neighbor, adjacency, acc, [neighbor | path])
  end

  defp handle_neighbor(:already_visited, _neighbor, _adjacency, acc, _path), do: acc

  defp record_cycle(nil, _ordered, _neighbor, acc), do: acc

  defp record_cycle(idx, ordered, neighbor, acc) do
    cycle = Enum.slice(ordered, idx..-1//1) ++ [neighbor]
    %{acc | cycles: [cycle | acc.cycles]}
  end
end
