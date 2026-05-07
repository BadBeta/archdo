defmodule Archdo.AST.StructRefs do
  @moduledoc """
  Extracts virtual edges from struct constructions and struct pattern
  matches: `%Foo{...}` and `%Foo{} = x` both reference module `Foo`
  but neither produces an edge in the BEAM's `:imports` chunk because
  struct construction compiles to a literal map operation, not a
  `Foo.__struct__/1` remote call.

  Companion to `Archdo.AST.NestedModules` (which handles parent → nested
  defmodule). This module handles the SIBLING case: e.g.
  `Bandit.HTTP1.Handler` constructs `%Bandit.HTTP1.Socket{...}`; both
  are top-level modules, neither nests the other.

  Excludes:
    - `%__MODULE__{...}` self-references (no anchor propagation needed)
    - struct references INSIDE `defmacro` bodies (those materialize in
      the consumer; `MacroEdges` extracts them)

  Returned shape: `%{using_module_name :: String.t() => [referenced_module_name :: String.t()]}`.
  Pure, deterministic, total — building-block per
  `elixir-planning/building-blocks.md`.
  """

  @type module_name :: String.t()
  @type edge_map :: %{module_name() => [module_name()]}

  @spec extract(Macro.t()) :: edge_map()
  def extract(ast) do
    ast
    |> collect([], [])
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {k, vs} -> {k, Enum.uniq(vs)} end)
  end

  # `ancestors` carries the enclosing-module name parts ("Outer.Inner" →
  # ["Outer", "Inner"]) for resolving the current module name. Edges
  # from `extract/1` are produced as `(current_module_name, target_module_name)`.

  defp collect({:defmodule, _, [{:__aliases__, _, parts}, kw]}, ancestors, edges)
       when is_list(parts) and is_list(kw) do
    full_name = qualified_name(ancestors, parts)
    body = extract_do(kw)
    nested_ancestors = ancestors ++ Enum.map(parts, &Atom.to_string/1)

    walk_body(body, full_name, nested_ancestors, edges)
  end

  defp collect({:__block__, _, stmts}, ancestors, edges) when is_list(stmts) do
    Enum.reduce(stmts, edges, &collect(&1, ancestors, &2))
  end

  defp collect(_, _, edges), do: edges

  # Walk a module body. Don't recurse into `defmacro` bodies — struct
  # references there are emitted into the consumer (handled by MacroEdges).
  defp walk_body({:__block__, _, stmts}, current, ancestors, edges) when is_list(stmts) do
    Enum.reduce(stmts, edges, &walk_stmt(&1, current, ancestors, &2))
  end

  defp walk_body(stmt, current, ancestors, edges) do
    walk_stmt(stmt, current, ancestors, edges)
  end

  # Skip macro bodies. They're not lexical references.
  defp walk_stmt({kind, _, _}, _, _, edges) when kind in [:defmacro, :defmacrop], do: edges

  # Recurse into nested defmodules (their bodies have their own `current`
  # context for struct references).
  defp walk_stmt({:defmodule, _, _} = mod, _current, ancestors, edges) do
    collect(mod, ancestors, edges)
  end

  # Walk every other top-level statement looking for struct references.
  defp walk_stmt(node, current, _ancestors, edges) do
    {_, hits} = Macro.prewalk(node, [], &collect_struct_ref/2)

    Enum.reduce(hits, edges, fn target, acc ->
      case target do
        ^current -> acc
        _ -> [{current, target} | acc]
      end
    end)
  end

  # Match `%Foo.Bar{...}` and `%Foo.Bar{} = x` shapes. The struct AST is
  # `{:%, _, [{:__aliases__, _, parts}, {:%{}, _, fields}]}`.
  defp collect_struct_ref({:%, _, [{:__aliases__, _, parts}, {:%{}, _, _}]} = node, hits)
       when is_list(parts) do
    {node, [aliases_to_string(parts) | hits]}
  end

  # Skip `%__MODULE__{...}` — self-reference.
  defp collect_struct_ref(
         {:%, _, [{:__MODULE__, _, _}, {:%{}, _, _}]} = node,
         hits
       ),
       do: {node, hits}

  defp collect_struct_ref(node, hits), do: {node, hits}

  defp extract_do([{:do, body} | _]), do: body
  defp extract_do([{{:__block__, _, [:do]}, body} | _]), do: body
  defp extract_do([_ | rest]), do: extract_do(rest)
  defp extract_do(_), do: nil

  defp qualified_name([], parts), do: Enum.map_join(parts, ".", &Atom.to_string/1)

  defp qualified_name(ancestors, parts) do
    Enum.join(ancestors, ".") <> "." <> Enum.map_join(parts, ".", &Atom.to_string/1)
  end

  defp aliases_to_string(parts), do: Enum.map_join(parts, ".", &Atom.to_string/1)
end
