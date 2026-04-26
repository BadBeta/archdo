defmodule Archdo.Rules.Boundary.LogicInLiveview do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @max_handle_event_nodes 10

  @impl true
  def id, do: "1.27"

  @impl true
  def description,
    do: "LiveView handle_event contains business logic — delegate to context modules"

  @impl true
  def analyze(file, ast, _opts) do
    cond do
      AST.test_file?(file) -> []
      liveview_module?(file, ast) -> check_handle_events(file, ast)
      true -> []
    end
  end

  defp liveview_module?(file, ast) do
    AST.live_view_file?(file) or uses_live_view?(ast)
  end

  defp uses_live_view?(ast) do
    AST.contains?(ast, fn
      {:use, _, [{:__aliases__, _, aliases} | _]} ->
        alias_str = Enum.map_join(aliases, ".", &to_string/1)
        String.contains?(alias_str, "Live")

      _ ->
        false
    end)
  end

  defp check_handle_events(file, ast) do
    ast
    |> AST.extract_functions(:public)
    |> Enum.filter(fn {name, arity, _, _, _} ->
      name == :handle_event and arity == 3
    end)
    |> Enum.filter(fn {_, _, _, _, body} ->
      body != nil and count_non_assign_nodes(body) > @max_handle_event_nodes
    end)
    |> Enum.map(fn {name, arity, meta, _, body} ->
      node_count = count_non_assign_nodes(body)

      Diagnostic.info("1.27",
        title: "Business logic in handle_event",
        message:
          "#{name}/#{arity} has #{node_count} non-assign AST nodes (limit: #{@max_handle_event_nodes}) — extract to a context",
        why:
          "LiveView handle_event callbacks should be thin: extract params, call a context " <>
            "function, assign the result. Business logic in handle_event can't be reused from " <>
            "controllers, background jobs, or other LiveViews. It also makes the LiveView harder " <>
            "to test — you need a browser/socket setup instead of a simple unit test.",
        alternatives: [
          Fix.new(
            summary: "Move the logic to a context module",
            detail:
              "Extract the business logic into a context function like " <>
                "`MyApp.Accounts.update_user(params)`. The handle_event becomes: " <>
                "extract params -> call context -> assign result to socket.",
            applies_when:
              "The handle_event does more than param extraction and socket assignment."
          ),
          Fix.new(
            summary: "Extract into a helper function in the LiveView",
            detail:
              "If the logic is LiveView-specific (e.g., computing multiple assigns from a result), " <>
                "extract it into a private function. This reduces handle_event size while keeping " <>
                "UI-specific logic close to where it's used.",
            applies_when: "The logic is about preparing assigns, not domain operations."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#1.27"],
        context: %{function: "#{name}/#{arity}", non_assign_nodes: node_count},
        file: file,
        line: AST.line(meta)
      )
    end)
  end

  # Count AST nodes excluding assign/assign_new calls and their arguments
  defp count_non_assign_nodes(body) do
    {_, count} =
      Macro.prewalk(body, 0, fn
        {:assign, _, _} = _node, acc -> {nil, acc}
        {:assign_new, _, _} = _node, acc -> {nil, acc}
        {:|>, _, [_, {:assign, _, _}]} = _node, acc -> {nil, acc}
        {:|>, _, [_, {:assign_new, _, _}]} = _node, acc -> {nil, acc}
        {:noreply, _, _} = node, acc -> {node, acc}
        {_, _, _} = node, acc -> {node, acc + 1}
        node, acc -> {node, acc}
      end)

    count
  end
end
