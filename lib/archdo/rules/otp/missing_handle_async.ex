defmodule Archdo.Rules.OTP.MissingHandleAsync do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.57"

  @impl true
  def description,
    do:
      "LiveView calls start_async/assign_async without handle_async/3 — async results " <>
        "silently ignored"

  # Functions that initiate an async operation in a LiveView. Their
  # results MUST be handled by `handle_async/3`; otherwise the success
  # / error tuple is dropped.
  @async_initiators [:start_async, :assign_async]

  @impl true
  def analyze(file, ast, _opts) do
    cond do
      AST.test_file?(file) -> []
      not live_view_module?(file, ast) -> []
      not body_starts_async?(ast) -> []
      handle_async_defined?(ast) -> []
      true -> [build_diagnostic(file, async_initiator_line(ast))]
    end
  end

  defp live_view_module?(file, ast) do
    AST.live_view_file?(file) or live_view_use_form?(ast)
  end

  defp live_view_use_form?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {:use, _, [{:__aliases__, _, parts} | _]} = node, _acc ->
          {node, parts == [:Phoenix, :LiveView] or List.last(parts) == :LiveView}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp body_starts_async?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {name, _, args} = node, _acc when name in @async_initiators and is_list(args) ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp handle_async_defined?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {:def, _, [{:handle_async, _, args} | _]} = node, _acc
        when is_list(args) and length(args) == 3 ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp async_initiator_line(ast) do
    {_, line} =
      Macro.prewalk(ast, nil, fn
        {name, meta, args} = node, nil when name in @async_initiators and is_list(args) ->
          {node, AST.line(meta)}

        node, acc ->
          {node, acc}
      end)

    line || 1
  end

  defp build_diagnostic(file, line) do
    Diagnostic.warning("5.57",
      title: "LiveView async without handle_async/3",
      message:
        "This LiveView calls `start_async` or `assign_async` but defines no " <>
          "`handle_async/3` — the async result will be delivered as a message that " <>
          "no callback handles, and is silently dropped.",
      why:
        "`start_async` and `assign_async` schedule work and send the result back to the " <>
          "LiveView process via a `:DOWN`-then-result-message protocol. Without " <>
          "`handle_async(name, result, socket)`, the result message is unhandled — the " <>
          "user sees a blank value forever and nobody notices in dev because the work " <>
          "was triggered, just not consumed.",
      alternatives: [
        Fix.new(
          summary: "Define handle_async/3 for every async name you start",
          detail:
            "def handle_async(:load_user, {:ok, user}, socket), do: " <>
              "{:noreply, assign(socket, :user, user)}\n" <>
              "def handle_async(:load_user, {:exit, reason}, socket), do: " <>
              "{:noreply, put_flash(socket, :error, \"...\")}",
          applies_when: "Always when starting async work in a LiveView."
        )
      ],
      references: ["GUIDE.md#5.57"],
      context: %{},
      file: file,
      line: line
    )
  end
end
