defmodule Archdo.Rules.OTP.FlatSupervision do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @max_children 7

  @impl true
  def id, do: "5.4"

  @impl true
  def description, do: "No flat supervision trees — group related processes"

  @impl true
  def analyze(file, ast, _opts) do
    find_large_child_lists(file, ast)
  end

  defp find_large_child_lists(file, ast) do
    # Find variable assignments that are child lists, then check Supervisor calls
    child_var_counts = find_child_list_assignments(ast)

    # Check direct list literals in Supervisor calls
    direct =
      Enum.map(
        AST.find_all(ast, fn
          {{:., _, [{:__aliases__, _, [:Supervisor]}, func]}, _meta, [children | _]}
          when func in [:init, :start_link] and is_list(children) ->
            length(children) > @max_children

          _ ->
            false
        end),
        fn {_, meta, [children | _]} ->
          {length(children), AST.line(meta)}
        end
      )

    # Check Supervisor calls with variable children
    indirect =
      Enum.map(
        AST.find_all(ast, fn
          {{:., _, [{:__aliases__, _, [:Supervisor]}, func]}, _meta, [{name, _, _} | _]}
          when func in [:init, :start_link] and is_atom(name) ->
            Map.get(child_var_counts, name, 0) > @max_children

          _ ->
            false
        end),
        fn {{:., _, _}, meta, [{name, _, _} | _]} ->
          {Map.get(child_var_counts, name, 0), AST.line(meta)}
        end
      )

    Enum.map(direct ++ indirect, fn {count, line} ->
      Diagnostic.info("5.4",
        title: "Flat supervision tree",
        message:
          "Supervisor manages #{count} direct children (> #{@max_children}) with no sub-supervisors",
        why:
          "A wide flat tree gives every child the same restart budget and the same failure domain. One " <>
            "misbehaving child can chew through max_restarts and bring down the whole subtree, including " <>
            "unrelated infrastructure. There is no way to apply different restart strategies to different " <>
            "groups, and the structure stops reflecting the failure boundaries you actually care about.",
        alternatives: [
          Fix.new(
            summary: "Group children under sub-supervisors by responsibility",
            detail:
              "Identify clusters in the child list (infrastructure: Repo/PubSub/Telemetry; workers; web " <>
                "endpoint; background jobs) and put each cluster under its own Supervisor. The top-level " <>
                "supervisor then has 3-5 children, each of which is a self-contained subtree.",
            example: """
            ```elixir
            children = [
              MyApp.Infra.Supervisor,   # Repo, PubSub, Telemetry
              MyApp.Workers.Supervisor, # background workers
              MyAppWeb.Endpoint
            ]
            ```
            """,
            applies_when: "The children naturally cluster into 2-4 groups."
          ),
          Fix.new(
            summary: "Promote a DynamicSupervisor for runtime-spawned children",
            detail:
              "If many of the children are similar workers spawned dynamically, hoist them under a single " <>
                "DynamicSupervisor child. The static supervisor only sees the DynamicSupervisor and the " <>
                "max_restarts budget for transient workers is isolated from infrastructure children.",
            applies_when: "The list contains many workers of the same type."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#5.4"],
        context: %{child_count: count, threshold: @max_children},
        file: file,
        line: line
      )
    end)
  end

  defp find_child_list_assignments(ast) do
    {_, assignments} =
      Macro.prewalk(ast, %{}, fn
        {:=, _, [{name, _, nil}, items]} = node, acc when is_atom(name) and is_list(items) ->
          {node, Map.put(acc, name, length(items))}

        node, acc ->
          {node, acc}
      end)

    assignments
  end
end
