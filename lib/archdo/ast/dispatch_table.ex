defmodule Archdo.AST.DispatchTable do
  @moduledoc """
  AST extractor for compile-time dispatch tables. Finds module
  attributes whose value is (or contains) module aliases, and
  returns the set of target module names as strings.

  Used by `Archdo.AnchorSet` to close the call-graph false-positive
  class where modules are reached through a data structure (map
  value, list element, keyword value) rather than a direct call. The
  `IndexRegistry.via/1` pattern (session 1 feedback) and the
  `@generators %{adapter: UA.Generator.Adapter, ...}` dispatch-table
  pattern (session 2 feedback) both reduce to this shape.

  ## Recognised patterns

      @generators %{adapter: UA.Generator.Adapter, behaviour: UA.Generator.Behaviour}
      @workers    [MyApp.WorkerA, MyApp.WorkerB]
      @handlers   [click: MyApp.Handlers.Click, submit: MyApp.Handlers.Submit]
      @routes     %{{:get, "/users"} => MyApp.Controllers.User}
      @config     %{group1: %{primary: MyApp.A}, group2: %{primary: MyApp.B}}
      @default    MyApp.Handlers.Default

  Module references appearing as map KEYS are NOT extracted — keys are
  used for lookup, not invocation, so the value side is what carries
  reachability.
  """

  alias Archdo.AST

  # Attribute names that are never dispatch tables — skip to avoid
  # false-positive extraction from typespec / doc attributes that
  # happen to mention module aliases. Defined above first use because
  # module attributes must precede the functions that reference them.
  @ignored_attrs [
    :moduledoc,
    :doc,
    :typedoc,
    :spec,
    :type,
    :typep,
    :opaque,
    :callback,
    :macrocallback,
    :impl,
    :behaviour,
    :behavior,
    :deprecated,
    :since,
    :tag,
    :describetag,
    :moduletag,
    # §§ M-fb-F5 — Archdo's own anchor / reachability markers carry atoms,
    # not dispatch-target modules; treating them as a dispatch table
    # would spuriously anchor unrelated modules if a future variant
    # used a module-form value.
    :archdo_anchor,
    :archdo_reachable_via
  ]

  # §§ M-fb-F2 — public extractor returns a deduplicated list of module
  # name strings sorted by first appearance order. Callers join into a
  # MapSet for reachability.
  @spec extract_module_values(Macro.t()) :: [String.t()]
  def extract_module_values(ast) do
    ast
    |> module_attr_values()
    |> Enum.flat_map(&module_aliases_in_value/1)
    |> Enum.uniq()
  end

  # Find every `@attr <value>` node and return the value AST.
  # The AST shape for `@foo bar` is `{:@, _, [{:foo, _, [bar]}]}`.
  defp module_attr_values(ast) do
    nodes =
      AST.find_all(ast, fn
        {:@, _, [{name, _, [_value]}]} when is_atom(name) -> name not in @ignored_attrs
        _ -> false
      end)

    Enum.map(nodes, fn {:@, _, [{_name, _, [value]}]} -> value end)
  end

  # Walk the value AST and collect every {:__aliases__, _, parts} node
  # that appears as a VALUE — not as a map key.
  defp module_aliases_in_value(value_ast) do
    {_, acc} = Macro.prewalk(value_ast, [], &collect_value_aliases/2)
    Enum.reverse(acc)
  end

  # §§ elixir-implementing: §2.3 — multi-clause prewalker dispatching on
  # AST node shape. Keys-as-modules are skipped by handling map literals
  # explicitly and recursing into values only.
  defp collect_value_aliases({:%{}, _, pairs}, acc) when is_list(pairs) do
    # Recurse into VALUES only, skipping keys.
    inner = Enum.flat_map(pairs, &aliases_in_pair_value/1)

    # Returning {nil, acc'} stops the prewalk from descending again —
    # we've already handled both sides of every pair.
    {nil, Enum.reverse(inner) ++ acc}
  end

  defp collect_value_aliases({:__aliases__, _, parts} = node, acc) when is_list(parts) do
    case Enum.all?(parts, &is_atom/1) do
      true -> {node, [AST.join_alias_parts(parts) | acc]}
      false -> {node, acc}
    end
  end

  defp collect_value_aliases(node, acc), do: {node, acc}

  # For each {key, value} pair from a map literal, recurse into the
  # value AST only.
  defp aliases_in_pair_value({_key, value}) do
    {_, acc} = Macro.prewalk(value, [], &collect_value_aliases/2)
    Enum.reverse(acc)
  end
end
