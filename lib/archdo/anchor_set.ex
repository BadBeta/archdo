defmodule Archdo.AnchorSet do
  @moduledoc """
  Reachability anchor discovery + transitive closure. An "anchor"
  is a module with externally-justified existence (Phoenix routes,
  Mix tasks, Oban workers, supervised processes, application
  lifecycle callbacks, public API entries, explicit
  `@archdo_anchor`, or `@archdo_reachable_via` with one or more of
  `:dispatch_table` / `:library_api` / `:supervisor_child` /
  `:behaviour_impl`). The closure is the set of modules transitively
  reachable from any anchor via the dependency graph. Used by CE-30
  (UnanchoredModule) and CE-31 (UnanchoredIsland). Public API.

  ## Escape hatches for off-call-graph reachability

  When a module is reached through indirection the AST walker can't
  see (a dispatch table the auto-detector misses, library re-export,
  runtime behaviour registration), declare the path explicitly:

      defmodule MyApp.Hidden do
        @archdo_reachable_via [:dispatch_table, :library_api]
      end

  The value is not enforced — it's documentation for future
  maintainers. The marker's presence is the anchor signal.
  """

  # §§ elixir-planning: §6 — anchor discovery + reachability closure for
  # CE-30 (unanchored module) and CE-31 (unanchored island). An "anchor"
  # is a module with externally-justified existence — Phoenix routes,
  # Mix tasks, Oban workers, supervised processes, application
  # lifecycle callbacks, public API entries, explicit `@archdo_anchor`
  # markers. The closure is the set of modules transitively reachable
  # from any anchor via the dependency graph.

  alias Archdo.{AST, Graph, Phoenix}
  alias Archdo.AST.DispatchTable

  @anchor_use_modules [
    {[:Mix, :Task], "Mix task entry point"},
    {[:Application], "Application lifecycle callback"},
    {[:Phoenix, :Router], "Phoenix router (HTTP route table)"},
    {[:Phoenix, :LiveView], "Phoenix LiveView (route-mounted)"},
    {[:Oban, :Worker], "Oban worker (queue-driven)"},
    {[:Phoenix, :Channel], "Phoenix channel (websocket route)"},
    {[:Phoenix, :Socket], "Phoenix socket handler (registered in endpoint via socket/3)"},
    # M-Plan8b: nested supervisors are themselves anchors. Their
    # children are extracted via add_supervisor_children/2.
    {[:Supervisor], "Supervisor (nested under app supervision tree)"},
    {[:DynamicSupervisor], "DynamicSupervisor (nested under app supervision tree)"}
  ]

  @doc """
  Compute the set of anchored module names from a list of `{file, ast}`
  tuples. Returns a `MapSet` of module names (strings).
  """
  @anchor_layers ~w(application_root controller live_view component router view operational migration)a

  @spec compute([{String.t(), Macro.t()}]) :: MapSet.t(String.t())
  def compute(file_asts) do
    Enum.reduce(file_asts, MapSet.new(), fn {file, ast}, acc ->
      acc
      |> add_anchors_from_use(ast)
      |> add_anchor_marker(ast)
      |> add_supervisor_children(ast)
      |> add_dispatch_table_targets(ast)
      |> add_phoenix_layer_anchor(file, ast)
    end)
  end

  # §§ M-fb-F2 — compile-time dispatch tables (session-2 feedback 3a).
  # A module-attribute holding a map / list / keyword with module-alias
  # VALUES treats those values as anchor-reachable: the dispatcher
  # invokes them by name through the table. Without this, every module
  # registered only through such a table looks unanchored to CE-30.
  defp add_dispatch_table_targets(acc, ast) do
    ast
    |> DispatchTable.extract_module_values()
    |> Enum.reduce(acc, &MapSet.put(&2, &1))
  end

  # §§ elixir-planning: §6 — reuse Archdo.Phoenix layer detection. Every
  # controller / LiveView / component / router / Mix task / migration /
  # application root is by definition an anchor — they're driven by
  # framework dispatch (HTTP routes, channel routes, ExUnit run, Mix
  # invocation, supervision tree). Without this, contexts and schemas
  # called only from controllers appear unanchored even though they're
  # transitively reached via a route.
  defp add_phoenix_layer_anchor(acc, file, ast) do
    layer = Phoenix.classify_file(file, ast).layer

    case layer in @anchor_layers do
      true -> MapSet.put(acc, AST.extract_module_name(ast))
      false -> acc
    end
  end

  @doc """
  Compute the transitive reachability closure from the anchor set,
  walking the module dependency graph forward (anchor → callees).
  Returns a `MapSet` containing the anchors plus every module
  reachable from them.
  """
  @spec closure(MapSet.t(String.t()), Graph.t()) :: MapSet.t(String.t())
  def closure(anchors, %Graph{} = graph) do
    walk(MapSet.to_list(anchors), graph, anchors)
  end

  defp walk([], _graph, visited), do: visited

  defp walk([module | rest], graph, visited) do
    targets =
      graph
      |> Graph.dependencies(module)
      |> Enum.map(& &1.target)
      |> Enum.reject(&MapSet.member?(visited, &1))

    walk(targets ++ rest, graph, MapSet.union(visited, MapSet.new(targets)))
  end

  # --- anchor discovery from `use Foo` ---

  defp add_anchors_from_use(acc, ast) do
    module_name = AST.extract_module_name(ast)

    case anchor_via_use?(ast) do
      true -> MapSet.put(acc, module_name)
      false -> acc
    end
  end

  defp anchor_via_use?(ast) do
    AST.contains?(ast, fn
      {:use, _, [{:__aliases__, _, parts} | _]} when is_list(parts) ->
        Enum.any?(@anchor_use_modules, fn {anchor_parts, _} ->
          parts == anchor_parts
        end)

      _ ->
        false
    end)
  end

  # --- @archdo_anchor / @archdo_reachable_via markers ---
  #
  # `@archdo_anchor` is the long-standing "this module is reachable, trust
  # me" marker. `@archdo_reachable_via :atom` / `[atom, ...]` (M-fb-F5)
  # is the newer typed form — declares WHICH off-call-graph dispatch
  # surface makes the module reachable. Both anchor the holding module.
  #
  # Canonical `@archdo_reachable_via` values (not enforced — anything
  # goes, the value is documentation for future maintainers):
  #   :dispatch_table   — values in a compile-time map / list
  #   :library_api      — re-exported from a public module via defdelegate
  #   :supervisor_child — listed in a supervisor's children
  #   :behaviour_impl   — registered behaviour implementation
  defp add_anchor_marker(acc, ast) do
    has_marker? =
      AST.contains?(ast, fn
        {:@, _, [{:archdo_anchor, _, _}]} -> true
        {:@, _, [{:archdo_reachable_via, _, _}]} -> true
        _ -> false
      end)

    case has_marker? do
      true -> MapSet.put(acc, AST.extract_module_name(ast))
      false -> acc
    end
  end

  # --- supervisor children inside Application.start/2 OR nested
  # `use Supervisor` / `use DynamicSupervisor` modules.
  # M-Plan8b: previously gated on `use Application` only; nested
  # sub-supervisors were invisible. Anchors flow transitively from
  # the top supervisor down through every supervised child.

  defp add_supervisor_children(acc, ast) do
    case supervisor_module?(ast) do
      false ->
        acc

      true ->
        ast
        |> children_modules()
        |> Enum.reduce(acc, &MapSet.put(&2, &1))
    end
  end

  # §§ elixir-implementing: §2.1 — multi-clause membership match. A
  # module IS a supervisor when its body uses Application (top-level),
  # Supervisor, or DynamicSupervisor.
  defp supervisor_module?(ast) do
    AST.contains?(ast, fn
      {:use, _, [{:__aliases__, _, [:Application]} | _]} -> true
      {:use, _, [{:__aliases__, _, [:Supervisor]} | _]} -> true
      {:use, _, [{:__aliases__, _, [:DynamicSupervisor]} | _]} -> true
      _ -> false
    end)
  end

  # Walk the AST for any literal list whose elements look like child specs:
  # `Foo`, `{Foo, opts}`, etc. This catches the common
  # `children = [MyApp.Repo, {Phoenix.PubSub, name: ...}]` pattern.
  defp children_modules(ast) do
    AST.find_all(ast, fn
      list when is_list(list) -> Enum.any?(list, &child_spec_shape?/1)
      _ -> false
    end)
    |> Enum.flat_map(&extract_child_modules/1)
    |> Enum.uniq()
  end

  defp child_spec_shape?({:__aliases__, _, parts}) when is_list(parts) do
    Enum.all?(parts, &is_atom/1)
  end

  defp child_spec_shape?({:{}, _, [{:__aliases__, _, _} | _]}), do: true
  defp child_spec_shape?({{:__aliases__, _, _}, _opts}), do: true
  defp child_spec_shape?(_), do: false

  defp extract_child_modules(list) when is_list(list) do
    Enum.flat_map(list, &extract_child_module/1)
  end

  defp extract_child_module({:__aliases__, _, parts}) when is_list(parts) do
    case Enum.all?(parts, &is_atom/1) do
      true -> [AST.join_alias_parts(parts)]
      false -> []
    end
  end

  defp extract_child_module({{:__aliases__, _, parts}, _opts}) when is_list(parts) do
    [AST.join_alias_parts(parts)]
  end

  defp extract_child_module({:{}, _, [{:__aliases__, _, parts} | _]}) when is_list(parts) do
    [AST.join_alias_parts(parts)]
  end

  # literal_encoder wraps tuple literals as `{:__block__, _, [{tuple}]}`.
  # Unwrap and recurse so `{Phoenix.PubSub, name: ...}` still surfaces.
  defp extract_child_module({:__block__, _, [inner]}), do: extract_child_module(inner)
  defp extract_child_module(_), do: []
end
