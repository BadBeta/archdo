defmodule Archdo.Graph do
  @moduledoc """
  Module-level dependency graph extracted from source ASTs.

  Build with `build/1`, query with `dependencies/2` /
  `dependents/2` / `find_cycles/2`. The graph captures `alias`,
  `import`, `use`, qualified remote calls (with short-form
  alias-table resolution), `defdelegate ..., to: ...`,
  `__MODULE__.Sub` references, `%Foo.Bar{...}` struct construction,
  and module-attribute registry lists. See GUIDE.md §3.4.8 for
  the full extraction shape.

  Public API for rule writers and metrics consumers. The compiled
  counterpart `Archdo.Compiled.Graph` covers BEAM-level analysis
  beyond AST reach.
  """

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
    file_asts
    |> Enum.reduce(%__MODULE__{}, fn {file, ast}, graph ->
      analyze_file(graph, file, ast)
    end)
    |> resolve_macro_alias_suffixes()
  end

  # Project-wide post-processing: macro-injected aliases (e.g. from
  # `use AppWeb, :controller` expanding to `quote do alias App.Policies
  # ... end`) are invisible to the per-file alias_table. Source like
  # `plug Authorize, [Policies.Admin.Episode, :podcast]` therefore
  # produces an edge to `"Policies.Admin.Episode"` — a phantom name
  # not matching any defined module.
  #
  # Heuristic: for any edge whose target is NOT a defined module,
  # check whether EXACTLY ONE defined module ends with the target's
  # dot-segments. If so, substitute. If zero or multiple match,
  # leave as-is (ambiguous → safe to skip).
  defp resolve_macro_alias_suffixes(%__MODULE__{} = graph) do
    defined = MapSet.new(graph.modules)

    suffix_index =
      graph.modules
      |> MapSet.to_list()
      |> Enum.reduce(%{}, fn full_name, acc ->
        full_name
        |> String.split(".")
        |> tail_suffixes()
        |> Enum.reduce(acc, fn suffix, inner ->
          Map.update(inner, suffix, [full_name], &[full_name | &1])
        end)
      end)

    rewritten_edges =
      Enum.map(graph.edges, fn edge -> rewrite_edge(edge, defined, suffix_index) end)

    new_by_source =
      Enum.reduce(rewritten_edges, %{}, fn edge, acc ->
        Map.update(acc, edge.source, [edge], &[edge | &1])
      end)

    %{graph | edges: rewritten_edges, edges_by_source: new_by_source}
  end

  # Yield "Foo.Bar.Baz", "Bar.Baz", "Baz" — every dot-segment suffix
  # except the empty one. Used to index modules by every short-form
  # they could be referenced as.
  defp tail_suffixes(parts) when is_list(parts) and length(parts) >= 1 do
    1..length(parts)
    |> Enum.map(fn drop_n -> parts |> Enum.drop(drop_n - 1) |> Enum.join(".") end)
    |> Enum.reject(&(&1 == ""))
  end

  defp rewrite_edge(edge, defined, suffix_index) do
    case MapSet.member?(defined, edge.target) do
      true ->
        edge

      false ->
        case Map.get(suffix_index, edge.target, []) do
          [single] -> %{edge | target: single}
          _ -> edge
        end
    end
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

  # State threaded through the traversal:
  #   :stack        — module-scope stack. Head is the current `defmodule`'s
  #                   {fully_qualified_name, alias_table}. Pre-visitor
  #                   pushes on `defmodule` enter; post-visitor pops on
  #                   exit. This restores the OUTER module's scope after
  #                   walking a nested defmodule. Without the stack, code
  #                   following a nested defmodule in the parent's body
  #                   was misattributed to the inner module.
  #   :alias_table  — built up from `alias` declarations within the
  #                   current scope. Used to resolve short-form references
  #                   (`Runner.foo()` after `alias Archdo.Runner`) into
  #                   fully-qualified module names. Without this, every
  #                   short-form call produced a dangling edge to a
  #                   bare-name target that didn't match any module.
  defp extract_edges(ast, file) do
    initial = %{stack: [], alias_table: %{}}

    {_, {_state, edges}} =
      Macro.traverse(
        ast,
        {initial, []},
        # PRE: enter defmodule — push the new module + its current alias
        # table onto the stack and start a fresh alias table for the new
        # scope. Other nodes pass through untouched on the way in.
        fn
          {:defmodule, _, [{:__aliases__, _, aliases} | _]} = node, {state, edges}
          when is_atom(hd(aliases)) ->
            mod = safe_concat(aliases)
            new_stack = [{mod, state.alias_table} | state.stack]
            {node, {%{stack: new_stack, alias_table: %{}}, edges}}

          node, acc ->
            {node, acc}
        end,
        # POST: every node we care about lives here so the alias table
        # is observed AFTER the alias declarations on the same level
        # have been processed by their own pre-visit. (Aliases in a
        # module body appear as siblings of subsequent calls, and post
        # order ensures sibling order is respected.)
        fn
          # Leave defmodule — pop the stack, restoring the outer scope.
          {:defmodule, _, [{:__aliases__, _, aliases} | _]} = node, {state, edges}
          when is_atom(hd(aliases)) ->
            new_state = pop_module_scope(state)
            {node, {new_state, edges}}

          node, acc ->
            visit_post(node, acc, file)
        end
      )

    Enum.reverse(edges)
  end

  defp pop_module_scope(%{stack: [_top]}) do
    %{stack: [], alias_table: %{}}
  end

  defp pop_module_scope(%{stack: [_top, {_outer_mod, outer_table} | _] = stack}) do
    [_popped | rest] = stack
    %{stack: rest, alias_table: outer_table}
  end

  defp pop_module_scope(%{stack: []} = state), do: state

  # current_module/1 reads the head of the scope stack.
  defp current_module(%{stack: [{mod, _} | _]}), do: mod
  defp current_module(_), do: nil

  # Single post-visitor used by Macro.traverse. Dispatches on the node
  # shape via multi-clause helpers below — keeps the case-explosion
  # out of the hot path. Skips early when no module is in scope.
  defp visit_post(node, {%{stack: []} = state, edges}, _file), do: {node, {state, edges}}

  # alias Foo.Bar
  defp visit_post(
         {:alias, meta, [{:__aliases__, _, parts}]} = node,
         {state, edges},
         file
       ) do
    handle_simple_alias(parts, nil, state, edges, node, file, meta)
  end

  # alias Foo.Bar, as: Quux (bare-atom keyword key)
  defp visit_post(
         {:alias, meta, [{:__aliases__, _, parts}, [{:as, {:__aliases__, _, [as_name]}}]]} = node,
         {state, edges},
         file
       )
       when is_atom(as_name) do
    handle_simple_alias(parts, as_name, state, edges, node, file, meta)
  end

  # alias Foo.Bar, as: Quux (literal-encoder-wrapped keyword key)
  defp visit_post(
         {:alias, meta,
          [
            {:__aliases__, _, parts},
            [{{:__block__, _, [:as]}, {:__aliases__, _, [as_name]}}]
          ]} = node,
         {state, edges},
         file
       )
       when is_atom(as_name) do
    handle_simple_alias(parts, as_name, state, edges, node, file, meta)
  end

  # alias Foo.{Bar, Baz}
  defp visit_post(
         {:alias, meta, [{{:., _, [{:__aliases__, _, prefix_parts}, :{}]}, _, suffixes}]} = node,
         {state, edges},
         file
       ) do
    handle_multi_alias(prefix_parts, suffixes, state, edges, node, file, meta)
  end

  # import Foo.Bar
  defp visit_post(
         {:import, meta, [{:__aliases__, _, parts} | _]} = node,
         {state, edges},
         file
       ) do
    handle_resolved_edge(parts, :import, state, edges, node, file, meta)
  end

  # use Foo.Bar
  defp visit_post(
         {:use, meta, [{:__aliases__, _, parts} | _]} = node,
         {state, edges},
         file
       ) do
    handle_resolved_edge(parts, :use, state, edges, node, file, meta)
  end

  # Remote call: Foo.bar() / Foo.Bar.baz()
  defp visit_post(
         {{:., meta, [{:__aliases__, _, parts}, _func]}, _, _args} = node,
         {state, edges},
         file
       ) do
    handle_resolved_edge(parts, @call_type, state, edges, node, file, meta)
  end

  # apply(Foo, :func, args)
  defp visit_post(
         {:apply, meta, [{:__aliases__, _, parts}, _fn_atom, _args]} = node,
         {state, edges},
         file
       ) do
    handle_resolved_edge(parts, :dynamic_dispatch, state, edges, node, file, meta)
  end

  # %Foo.Bar{...} struct construction or pattern match
  defp visit_post(
         {:%, meta, [{:__aliases__, _, parts}, {:%{}, _, _}]} = node,
         {state, edges},
         file
       ) do
    handle_resolved_edge(parts, @call_type, state, edges, node, file, meta)
  end

  # defdelegate name(args), to: SomeModule, as: ...
  defp visit_post(
         {:defdelegate, meta, [_head, opts]} = node,
         {state, edges},
         file
       )
       when is_list(opts) do
    case extract_delegate_target(opts) do
      nil -> {node, {state, edges}}
      parts -> handle_resolved_edge(parts, @call_type, state, edges, node, file, meta)
    end
  end

  # Phoenix plug pipeline: `plug Module` and `plug Module, opts`.
  # Plug invokes Module.init/1 and Module.call/2 at runtime; opts
  # may contain additional module references that the plug
  # dispatches to (e.g. `plug Authorize, [Policies.Episode, :podcast]`).
  # Without this carve-out, every plug-only-referenced module
  # appears orphan to CE-30 even though it's called every request.
  defp visit_post(
         {:plug, meta, [{:__aliases__, _, parts} | rest]} = node,
         {state, edges},
         file
       )
       when is_list(parts) and is_atom(hd(parts)) do
    {_, {_, edges_with_plug}} =
      handle_resolved_edge(parts, :registry, state, edges, node, file, meta)

    edges_with_opts = collect_alias_refs_in_args(rest, state, edges_with_plug, file, meta)
    {node, {state, edges_with_opts}}
  end

  defp visit_post(node, acc, _file), do: {node, acc}

  # Walk a value (typically a `plug` opts list / kw-list) collecting
  # every `{:__aliases__, _, parts}` reference and emitting a
  # `:registry`-typed edge from the current module to each. Recursive
  # — handles nested lists / tuples / maps.
  defp collect_alias_refs_in_args(value, state, edges, file, meta) do
    {_, refs} = Macro.prewalk(value, [], &collect_alias_node/2)

    Enum.reduce(refs, edges, fn parts, acc_edges ->
      case resolve_alias(parts, state) do
        nil ->
          acc_edges

        target ->
          edge = %{
            source: current_module(state),
            target: target,
            type: :registry,
            file: file,
            line: AST.line(meta)
          }

          [edge | acc_edges]
      end
    end)
  end

  defp collect_alias_node({:__aliases__, _, parts} = node, acc) when is_list(parts) do
    case Enum.all?(parts, &is_atom/1) do
      true -> {node, [parts | acc]}
      false -> {node, acc}
    end
  end

  defp collect_alias_node(node, acc), do: {node, acc}

  defp handle_simple_alias(parts, as_name, state, edges, node, file, meta) do
    case safe_concat(parts) do
      nil ->
        {node, {state, edges}}

      target ->
        edge = %{
          source: current_module(state),
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
        accumulate_multi_alias(suffix, acc, prefix_parts, current_module(state), file, meta)
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

  # Find the `to:` keyword option's value in a `defdelegate` opts list.
  # Returns the alias-parts list (e.g. `[:Foo, :Bar]` or
  # `[{:__MODULE__, _, _}, :Bar]`) or nil if absent / non-alias.
  # Both bare-atom (`:to`) and literal-encoder-wrapped
  # (`{:__block__, _, [:to]}`) keyword keys appear in practice.
  defp extract_delegate_target(opts) do
    Enum.find_value(opts, fn
      {{:__block__, _, [:to]}, {:__aliases__, _, parts}} -> parts
      {:to, {:__aliases__, _, parts}} -> parts
      _ -> nil
    end)
  end

  # Resolve `parts` via the alias table and emit an edge of the given
  # `type`. Used for `import`, `use`, remote calls, and `apply/3` —
  # all four resolve short-form aliases the same way and emit the
  # same edge shape, only the `type` differs.
  defp handle_resolved_edge(parts, type, state, edges, node, file, meta) do
    case resolve_alias(parts, state) do
      nil ->
        {node, {state, edges}}

      target ->
        edge = %{
          source: current_module(state),
          target: target,
          type: type,
          file: file,
          line: AST.line(meta)
        }

        {node, {state, [edge | edges]}}
    end
  end

  # Resolve an alias-parts list to a fully-qualified module name. Handles:
  #   [{:__MODULE__, _, _} | rest]  — the `__MODULE__.Foo.Bar` form,
  #                                   resolved against the current module
  #                                   in scope. Used heavily by
  #                                   `defdelegate ..., to: __MODULE__.Foo`.
  #   [single_atom]                 — short-form alias; alias_table lookup
  #                                   with bare-name fallback.
  #   [atom, atom, ...]             — multi-segment fully-qualified;
  #                                   safe_concat/1.
  defp resolve_alias([{:__MODULE__, _, _} | rest], state) when is_list(rest) do
    case current_module(state) do
      nil ->
        nil

      mod ->
        case Enum.all?(rest, &is_atom/1) do
          true ->
            suffix = Enum.map_join(rest, ".", &Atom.to_string/1)
            mod <> "." <> suffix

          false ->
            nil
        end
    end
  end

  defp resolve_alias([single], state) when is_atom(single) do
    case Map.fetch(state.alias_table, single) do
      {:ok, full} -> full
      :error -> Atom.to_string(single)
    end
  end

  # Multi-segment reference: `Foo.Bar.baz()` parses with parts =
  # [:Foo, :Bar]. If `Foo` is in the alias_table (declared as
  # `alias X.Foo`), prepend the resolved prefix and append the
  # remaining segments. Otherwise fall back to safe_concat — handles
  # fully-qualified `MyApp.Foo.Bar` references.
  defp resolve_alias([first | rest] = parts, state)
       when is_atom(first) and is_list(rest) and rest != [] do
    case Map.fetch(state.alias_table, first) do
      {:ok, prefix} ->
        case Enum.all?(rest, &is_atom/1) do
          true -> prefix <> "." <> Enum.map_join(rest, ".", &Atom.to_string/1)
          false -> safe_concat(parts)
        end

      :error ->
        safe_concat(parts)
    end
  end

  defp resolve_alias(parts, _state) when is_list(parts) do
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
