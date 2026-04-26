defmodule Archdo.Rules.Boundary.LargeLiveviewAssigns do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @max_assigns 15

  @impl true
  def id, do: "1.16"

  @impl true
  def description,
    do: "LiveView with too many assigns — use streams for collections, reduce socket size"

  @impl true
  def analyze(file, ast, _opts) do
    cond do
      AST.test_file?(file) -> []
      AST.live_view_file?(file) or uses_live_view?(ast) -> check_assigns(file, ast)
      true -> []
    end
  end

  defp check_assigns(file, ast) do
    # Count distinct assign keys across all mount/handle_event/handle_info
    assign_keys = collect_assign_keys(ast)
    count = MapSet.size(assign_keys)

    if count > @max_assigns do
      module_name = AST.extract_module_name(ast)

      [
        Diagnostic.info("1.16",
          title: "LiveView with many assigns",
          message:
            "#{module_name} uses #{count} distinct socket assigns (threshold: #{@max_assigns})",
          why:
            "Every socket assign is serialized and diffed on each render cycle. Large numbers " <>
              "of assigns increase memory per connection and slow down the diff engine. Collections " <>
              "assigned directly (lists of records) are the worst — use streams instead. Many " <>
              "assigns also signal the LiveView is doing too much and should be split into components.",
          alternatives: [
            Fix.new(
              summary: "Use streams for collections",
              detail:
                "Replace `assign(socket, :posts, Repo.all(Post))` with " <>
                  "`stream(socket, :posts, Repo.all(Post))`. Streams only send diffs, " <>
                  "not the entire collection on each update.",
              applies_when: "Any assign holds a list of records."
            ),
            Fix.new(
              summary: "Extract into live components",
              detail:
                "Split the LiveView into focused live components, each managing its own assigns. " <>
                  "The parent LiveView becomes thinner.",
              applies_when: "The assigns serve distinct UI concerns."
            ),
            Fix.new(
              summary: "Derive computed values in templates instead of assigning",
              detail:
                "If some assigns are computed from others (e.g., `can_edit?`, `filtered_list`), " <>
                  "compute them in the template or a helper instead of assigning separately.",
              applies_when: "Some assigns are derived from other assigns."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#1.16"],
          context: %{module: module_name, assign_count: count},
          file: file,
          line: 1
        )
      ]
    else
      []
    end
  end

  defp collect_assign_keys(ast) do
    {_, keys} =
      Macro.prewalk(ast, MapSet.new(), fn
        # assign(socket, :key, value)
        {:assign, _, [_, key, _]} = node, acc when is_atom(key) ->
          {node, MapSet.put(acc, key)}

        {:assign, _, [_, {key, _, _}, _]} = node, acc when is_atom(key) ->
          {node, MapSet.put(acc, key)}

        # Piped: |> assign(:key, value) — 2 args (socket piped)
        {:assign, _, [key, _]} = node, acc when is_atom(key) ->
          {node, MapSet.put(acc, key)}

        {:assign, _, [{key, _, _}, _]} = node, acc when is_atom(key) ->
          {node, MapSet.put(acc, key)}

        # assign(socket, key: value, key2: value2)
        {:assign, _, [_, kw]} = node, acc when is_list(kw) ->
          new_keys =
            kw
            |> Enum.map(fn
              {k, _} when is_atom(k) -> k
              _ -> nil
            end)
            |> Enum.reject(&is_nil/1)

          {node, Enum.reduce(new_keys, acc, &MapSet.put(&2, &1))}

        # assign_new(socket, :key, fn -> ... end)
        {:assign_new, _, [_, key, _]} = node, acc when is_atom(key) ->
          {node, MapSet.put(acc, key)}

        node, acc ->
          {node, acc}
      end)

    keys
  end

  defp uses_live_view?(ast) do
    AST.contains?(ast, fn
      {:use, _, [{:__aliases__, _, aliases} | _]} ->
        case List.last(aliases) do
          :LiveView -> true
          _ -> false
        end

      _ ->
        false
    end)
  end
end
