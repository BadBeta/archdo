defmodule Archdo.AST.MacroEdges do
  @moduledoc """
  Extracts virtual call edges from `defmacro` / `defmacrop` bodies.

  A library macro can quote calls to sibling modules; those calls
  materialize inside the consumer's compiled module after `use SomeLib`.
  Static analysis of the library in isolation cannot see the call edge
  in the library's own BEAM. This module reconstructs those edges by
  walking the macro body's AST.

  Two forms are recognised inside macro bodies:

    1. Aliased module reference:  `alias Foo.Bar.Baz` — the module Baz
       is named explicitly. The fact that the alias appears INSIDE a
       `quote do ... end` is the strongest signal that the consumer's
       module will reference it.

    2. Fully-qualified remote call: `Foo.Bar.Baz.fn(args)` — the module
       Baz is the call target. The `:.` AST node with a left side that
       is `{:__aliases__, _, [...]}` names the module.

  Erlang-style `:atom.fun()` calls are ignored (they don't name an Elixir
  module).

  Returned shape: `%{defining_module_name :: String.t() => [referenced_module_name :: String.t()]}`.
  Module names are kept as strings; conversion to atoms happens at the
  consumer (`Archdo.run/2`) so missing-atom edges are filtered uniformly
  with other edge sources.

  Public for direct testing — building-block per
  `elixir-planning/building-blocks.md`: pure, deterministic, total,
  errors-as-empty-map.
  """

  alias Archdo.AST

  @type module_name :: String.t()
  @type edge_map :: %{module_name() => [module_name()]}

  @spec extract(Macro.t()) :: edge_map()
  def extract(ast) do
    case AST.extract_module_name(ast) do
      "Unknown" -> %{}
      mod_name -> extract_for_module(ast, mod_name)
    end
  end

  defp extract_for_module(ast, mod_name) do
    refs =
      ast
      |> macro_bodies()
      |> Enum.flat_map(&module_references/1)
      |> Enum.uniq()

    case refs do
      [] -> %{}
      _ -> %{mod_name => refs}
    end
  end

  # Collect bodies of every defmacro / defmacrop in the module AST.
  defp macro_bodies(ast) do
    {_, bodies} = Macro.prewalk(ast, [], &collect_macro_body/2)
    bodies
  end

  # Guarded macro: defmacro f(x) when guard, do: body
  defp collect_macro_body(
         {macro_kind, _meta, [{:when, _, [{_name, _, _args} | _]}, body]} = node,
         acc
       )
       when macro_kind in [:defmacro, :defmacrop] do
    {node, [body | acc]}
  end

  defp collect_macro_body(
         {macro_kind, _meta, [{_name, _, _args}, body]} = node,
         acc
       )
       when macro_kind in [:defmacro, :defmacrop] do
    {node, [body | acc]}
  end

  defp collect_macro_body(node, acc), do: {node, acc}

  # Walk a macro body and collect every Elixir-module reference.
  defp module_references(body) do
    {_, refs} = Macro.prewalk(body, [], &collect_reference/2)
    Enum.reverse(refs)
  end

  # `alias Foo.Bar.Baz` — single alias inside a quote (or anywhere in the
  # macro body). The alias IS the reference to the module.
  defp collect_reference({:alias, _, [{:__aliases__, _, parts} | _]} = node, acc)
       when is_list(parts) do
    {node, [aliases_to_string(parts) | acc]}
  end

  # `Foo.Bar.Baz.fun(args)` — remote call. The `.` node's left operand is
  # the module. Match the `__aliases__` shape; ignore `:gen_server.call`
  # style (left operand is an atom literal, not aliases).
  defp collect_reference(
         {{:., _, [{:__aliases__, _, parts}, _fn]}, _, _args} = node,
         acc
       )
       when is_list(parts) do
    {node, [aliases_to_string(parts) | acc]}
  end

  defp collect_reference(node, acc), do: {node, acc}

  defp aliases_to_string(parts) do
    Enum.map_join(parts, ".", &Atom.to_string/1)
  end

  @doc """
  Extract function-level macro-emit calls.

  Returns `[{module_name :: String.t(), fn :: atom(), arity :: non_neg_integer()}]`
  for every fully-qualified `Mod.fn(args)` inside any `defmacro` /
  `defmacrop` body. Companion to `extract/1` — `extract/1` provides
  module-level reachability edges (sufficient for 1.26's closure walk);
  `extract_calls/1` provides function-level precision (needed by 6.24
  to suppress dead-public-function findings on functions actually
  called by the consumer's macro-injected code).

  Erlang-style `:atom.fun()` calls (where the module is an atom literal,
  not an Elixir module alias) are ignored.

  Pure, deterministic, total. Public for direct testing.
  """
  @spec extract_calls(Macro.t()) :: [{String.t(), atom(), non_neg_integer()}]
  def extract_calls(ast) do
    ast
    |> macro_bodies()
    |> Enum.flat_map(&function_call_refs/1)
    |> Enum.uniq()
  end

  defp function_call_refs(body) do
    {_, refs} = Macro.prewalk(body, [], &collect_call_ref/2)
    Enum.reverse(refs)
  end

  # `Foo.Bar.Baz.fun(args)` — collect the (mod_str, fun_atom, arity) triple.
  defp collect_call_ref(
         {{:., _, [{:__aliases__, _, parts}, fun]}, _, args} = node,
         acc
       )
       when is_list(parts) and is_atom(fun) and is_list(args) do
    {node, [{aliases_to_string(parts), fun, length(args)} | acc]}
  end

  defp collect_call_ref(node, acc), do: {node, acc}
end
