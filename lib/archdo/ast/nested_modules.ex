defmodule Archdo.AST.NestedModules do
  @moduledoc """
  Extracts virtual lexical-container edges from nested `defmodule`
  declarations.

  A nested `defmodule X do ... end` inside a parent module is part of
  the parent's implementation by definition. If the parent uses the
  child as a struct (`%X{...}`) or via pattern matching (`%X{} = state`),
  the BEAM's `:imports` chunk will have ZERO call edges from parent → X
  because struct construction compiles to a literal map operation, not
  a remote `__struct__/1` call.

  This module reconstructs the relationship by walking the source AST.
  Returned shape: `%{parent_module_name :: String.t() => [nested_full_name :: String.t()]}`.

  Quoted `defmodule` inside `defmacro` bodies is **excluded** — those
  modules materialize inside the CONSUMER's compilation, not the
  library's. Macro-emit edges are the right tool for that case
  (see `Archdo.AST.MacroEdges`).

  Pure, deterministic, total — passes the building-block 6-axis
  checklist. Public for direct testing.
  """

  @type module_name :: String.t()
  @type edge_map :: %{module_name() => [module_name()]}

  @spec extract(Macro.t()) :: edge_map()
  def extract(ast) do
    ast
    |> collect_pairs([])
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {k, vs} -> {k, Enum.uniq(vs)} end)
  end

  # `ancestors` is a list of name parts of the enclosing defmodules —
  # e.g. `["Outer", "Inner"]`. Returns a list of `{parent_name, child_name}`
  # pairs.

  defp collect_pairs({:defmodule, _, [{:__aliases__, _, parts}, kw]}, ancestors)
       when is_list(parts) and is_list(kw) do
    full_name = qualified_name(ancestors, parts)
    body = extract_do(kw)

    parent_pair =
      case ancestors do
        [] -> []
        _ -> [{Enum.join(ancestors, "."), full_name}]
      end

    nested_ancestors = ancestors ++ Enum.map(parts, &Atom.to_string/1)
    parent_pair ++ collect_pairs_in_body(body, nested_ancestors)
  end

  defp collect_pairs({:__block__, _, stmts}, ancestors) when is_list(stmts) do
    Enum.flat_map(stmts, &collect_pairs(&1, ancestors))
  end

  defp collect_pairs(_, _), do: []

  # Inside a module body: walk only top-level statements for nested
  # `defmodule`s. Do NOT descend into function bodies, defmacro bodies,
  # or quote blocks — defmodules quoted inside macros materialize in
  # the consumer's compilation, not lexically inside this file.
  defp collect_pairs_in_body({:__block__, _, stmts}, ancestors) when is_list(stmts) do
    Enum.flat_map(stmts, &collect_in_body_stmt(&1, ancestors))
  end

  defp collect_pairs_in_body(stmt, ancestors), do: collect_in_body_stmt(stmt, ancestors)

  defp collect_in_body_stmt({:defmodule, _, _} = node, ancestors) do
    collect_pairs(node, ancestors)
  end

  defp collect_in_body_stmt(_, _), do: []

  # `[do: body]` (bare keyword) or `[{{:__block__, _, [:do]}, body}, ...]`
  # (literal_encoder mode).
  defp extract_do([{:do, body} | _]), do: body
  defp extract_do([{{:__block__, _, [:do]}, body} | _]), do: body
  defp extract_do([_ | rest]), do: extract_do(rest)
  defp extract_do(_), do: nil

  defp qualified_name([], parts), do: Enum.map_join(parts, ".", &Atom.to_string/1)

  defp qualified_name(ancestors, parts) do
    Enum.join(ancestors, ".") <> "." <> Enum.map_join(parts, ".", &Atom.to_string/1)
  end
end
