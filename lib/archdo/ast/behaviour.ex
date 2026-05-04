defmodule Archdo.AST.Behaviour do
  @moduledoc """
  Behaviour-aware AST helpers — `@callback` discovery, `@behaviour`
  declaration resolution, project-level callback maps.

  Public API for rule writers; re-exported via `Archdo.AST` for
  backward compatibility with existing call sites.
  """

  alias Archdo.AST

  @doc """
  Build a project-level callback map from a list of `{file, ast}` tuples.
  For each module declaring `@callback name(args) :: return`, the result
  contains an entry `module_name => MapSet.of({name, arity})`.

  Used by rules that need to identify "is this function a callback
  implementation of a project-defined behaviour?" without relying on
  `@impl true` annotations (which older codebases often omit).
  """
  @spec collect_callbacks([{String.t(), Macro.t()}]) ::
          %{String.t() => MapSet.t({atom(), arity()})}
  def collect_callbacks(file_asts) do
    Enum.reduce(file_asts, %{}, fn {_file, ast}, acc -> add_module_callbacks(acc, ast) end)
  end

  defp add_module_callbacks(acc, ast) do
    case AST.extract_module_name(ast) do
      "Unknown" -> acc
      mod_name -> put_if_nonempty(acc, mod_name, scan_callback_specs(ast))
    end
  end

  defp put_if_nonempty(acc, _mod_name, callbacks) when callbacks == %MapSet{}, do: acc
  defp put_if_nonempty(acc, mod_name, callbacks), do: Map.put(acc, mod_name, callbacks)

  defp scan_callback_specs(ast) do
    {_, callbacks} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:@, _, [{:callback, _, [{:"::", _, [{name, _, args}, _ret]}]}]} = node, acc
        when is_atom(name) and is_list(args) ->
          {node, MapSet.put(acc, {name, length(args)})}

        {:@, _, [{:callback, _, [{:"::", _, [{name, _, nil}, _ret]}]}]} = node, acc
        when is_atom(name) ->
          {node, MapSet.put(acc, {name, 0})}

        node, acc ->
          {node, acc}
      end)

    callbacks
  end

  @doc """
  Resolve a module's `@behaviour Foo` declarations to the union of Foo's
  callbacks, given a project-level callback map (built by
  `collect_callbacks/1`).

  Returns a `MapSet.t({name, arity})` of every callback the module
  implicitly implements via its declared behaviours. Useful for rules
  that want to treat callback-impl public functions differently from
  ordinary public API.

  Behaviours unknown to the map (e.g. `GenServer` from OTP, or a
  library's behaviour that's outside the analyzed paths) contribute
  nothing — only project-defined behaviours resolve.
  """
  @spec implemented_callbacks(
          Macro.t(),
          %{String.t() => MapSet.t({atom(), arity()})}
        ) :: MapSet.t({atom(), arity()})
  def implemented_callbacks(ast, callbacks_map) when is_map(callbacks_map) do
    ast
    |> declared_names()
    |> Enum.reduce(MapSet.new(), fn behaviour_name, acc ->
      MapSet.union(Map.get(callbacks_map, behaviour_name, MapSet.new()), acc)
    end)
  end

  defp declared_names(ast) do
    {_, names} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:@, _, [{:behaviour, _, [{:__aliases__, _, parts}]}]} = node, acc when is_list(parts) ->
          name = parts |> Module.concat() |> AST.module_name()
          {node, MapSet.put(acc, name)}

        {:@, _, [{:behaviour, _, [atom]}]} = node, acc when is_atom(atom) ->
          {node, MapSet.put(acc, AST.module_name(atom))}

        node, acc ->
          {node, acc}
      end)

    names
  end
end
