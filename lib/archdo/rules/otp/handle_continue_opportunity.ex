defmodule Archdo.Rules.OTP.HandleContinueOpportunity do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.AST.Unwrap

  @impl true
  def id, do: "5.62"

  @impl true
  def description,
    do:
      "GenServer `init/1` does heavy work synchronously — defer via " <>
        "`{:ok, state, {:continue, term}}` and a `handle_continue/2` callback"

  # Heavy-work module aliases (matched by tail). Presence of any
  # call to one of these inside init/1 suggests the work belongs
  # in handle_continue/2 instead.
  @heavy_modules [
    [:Repo],
    [:Ecto, :Repo],
    [:HTTPoison],
    [:Req],
    [:Tesla],
    [:Finch],
    [:File],
    [:Process]
  ]

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    case AST.genserver_module?(ast) do
      false -> []
      true -> scan_init_callbacks(file, ast)
    end
  end

  defp scan_init_callbacks(file, ast) do
    {_, hits} =
      Macro.prewalk(ast, [], fn
        {:def, meta, [{:init, _, args}, kw]} = node, acc
        when is_list(args) and length(args) == 1 and is_list(kw) ->
          {node, maybe_collect(meta, kw, acc)}

        node, acc ->
          {node, acc}
      end)

    Enum.map(hits, fn line -> build_diagnostic(file, line) end)
  end

  defp maybe_collect(meta, kw, acc) do
    case Unwrap.kw_get(kw, :do) do
      {:ok, body} ->
        case violation?(body) do
          true -> [AST.line(meta) | acc]
          false -> acc
        end

      :error ->
        acc
    end
  end

  defp violation?(body) do
    not has_continue_in_return?(body) and contains_heavy_work?(body)
  end

  # Body returns `{:ok, state, {:continue, _}}` somewhere — already
  # using handle_continue, no violation.
  defp has_continue_in_return?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {:{}, _, [:ok, _state, {:{}, _, [:continue, _term]}]} = node, _acc ->
          {node, true}

        # 3-tuple `{:ok, state, {:continue, term}}`
        {:ok, _state, {:continue, _term}} = node, _acc ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp contains_heavy_work?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, mod_parts}, _fun]}, _, _} = node, _acc ->
          tail_match = [List.last(mod_parts)]
          {node, mod_parts in @heavy_modules or tail_match in @heavy_modules}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp build_diagnostic(file, line) do
    Diagnostic.info("5.62",
      title: "`init/1` does heavy work — defer via `handle_continue/2`",
      message:
        "This GenServer's `init/1` body calls a Repo / HTTP client / File operation " <>
          "synchronously. Heavy work in `init/1` blocks the supervisor's start sequence — " <>
          "every other child waits. Return `{:ok, state, {:continue, term}}` and do the " <>
          "work in `handle_continue/2`.",
      why:
        "Supervisor children start sequentially. While `init/1` is running, the supervisor " <>
          "blocks; siblings further down the start order wait. Heavy I/O in init means a " <>
          "slow Repo query / network call delays application boot. `handle_continue/2` " <>
          "(added Elixir 1.7 / OTP 21) lets `init/1` return fast, then runs the deferred " <>
          "work as the FIRST message the GenServer processes — same single-threaded " <>
          "guarantees, no boot delay.",
      alternatives: [
        Fix.new(
          summary: "Defer heavy work via handle_continue/2",
          detail:
            "@impl true\n" <>
              "def init(args), do: {:ok, %{}, {:continue, :load_data}}\n\n" <>
              "@impl true\n" <>
              "def handle_continue(:load_data, state) do\n" <>
              "  data = MyApp.Data.load_all()  # Heavy work runs AFTER init returns\n" <>
              "  {:noreply, %{state | data: data}}\n" <>
              "end",
          applies_when: "Always when init/1 has slow I/O or computation."
        )
      ],
      references: ["elixir-implementing/SKILL.md#9.5", "elixir-implementing/SKILL.md#9.6"],
      context: %{},
      file: file,
      line: line
    )
  end
end
