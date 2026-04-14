defmodule Archdo.Rules.OTP.UnboundedState do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.31"

  @impl true
  def description, do: "GenServer accumulating unbounded data in process state"

  @accumulation_funcs [
    {[:Map], [:put, :merge, :put_new]},
    {[:MapSet], [:put]},
    {[:Keyword], [:put, :merge, :put_new]}
  ]

  @cleanup_funcs [
    {[:Map], [:delete, :drop, :take]},
    {[:MapSet], [:delete]},
    {[:Keyword], [:delete, :drop]}
  ]

  @impl true
  def analyze(file, ast, _opts) do
    case AST.genserver_module?(ast) do
      false ->
        []
      true ->
      check_unbounded_growth(file, ast)
    end
  end

  defp check_unbounded_growth(file, ast) do
    callbacks = AST.extract_callbacks(ast)
    module_name = AST.extract_module_name(ast)

    accumulation_cbs = [:handle_cast, :handle_info, :handle_call]
    cleanup_cbs = [:handle_cast, :handle_info, :handle_call, :handle_continue]

    has_accumulation? = any_callback_matches?(callbacks, accumulation_cbs, &has_accumulation?/1)
    has_cleanup? = any_callback_matches?(callbacks, cleanup_cbs, &has_cleanup?/1)
    has_list_prepend? = any_callback_matches?(callbacks, [:handle_cast, :handle_info], &has_list_prepend?/1)

    build_diagnostics(file, module_name, has_accumulation?, has_cleanup?, has_list_prepend?)
  end

  defp any_callback_matches?(callbacks, cb_names, check_fn) do
    Enum.any?(cb_names, fn cb ->
      (callbacks[cb] || [])
      |> Enum.any?(fn {_, _, body} -> check_fn.(body) end)
    end)
  end

  defp build_diagnostics(file, module_name, true, false, _) do
    [unbounded_diag(file, module_name, :map_accumulation)]
  end

  defp build_diagnostics(file, module_name, _, false, true) do
    [unbounded_diag(file, module_name, :list_prepend)]
  end

  defp build_diagnostics(_, _, _, _, _), do: []

  defp unbounded_diag(file, module_name, kind) do
    Diagnostic.info("5.31",
      title: "Unbounded GenServer state",
      message:
        case kind do
          :map_accumulation -> "#{module_name} grows a Map in state via Map.put/merge with no Map.delete"
          :list_prepend -> "#{module_name} prepends to a list in state with no pruning"
        end,
      why:
        "GenServer state lives on the process heap. When state grows without bound, garbage collection " <>
          "pauses lengthen and eventually block all message handling. Every `handle_call` reply copies the " <>
          "relevant data from the server heap to the caller. The state is also lost on crash, while ETS with " <>
          "an heir survives. Unbounded growth is one of the most common production-stability issues in BEAM apps.",
      alternatives: [
        Fix.new(
          summary: "Add periodic pruning (e.g. `:timer.send_interval/2 :prune`)",
          detail:
            "Schedule a recurring `:prune` message that drops old entries (LRU, TTL, max size). The state " <>
              "stays bounded and GC pauses stay short.",
          example: """
          ```elixir
          def init(_) do
            :timer.send_interval(60_000, :prune)
            {:ok, %{cache: %{}}}
          end

          def handle_info(:prune, state) do
            {:noreply, %{state | cache: keep_recent(state.cache)}}
          end
          ```
          """,
          applies_when: "You need to keep the data on the GenServer process."
        ),
        Fix.new(
          summary: "Move the data into ETS",
          detail:
            "Public ETS tables don't live on the GenServer's heap, so growth doesn't slow down the message " <>
              "loop. Combine with a heir if you need the data to survive process restarts.",
          applies_when: "Concurrent reads matter or the data is large."
        ),
        Fix.new(
          summary: "Use a bounded data structure (ring buffer, fixed-size LRU)",
          detail:
            "If the data is naturally bounded (latest N events, sliding window of metrics), use a ring " <>
              "buffer or library that enforces the bound at insertion time so growth simply cannot exceed N.",
          applies_when: "The use case has a natural maximum size."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#5.31"],
      context: %{module: module_name, kind: kind},
      file: file,
      line: 1
    )
  end

  defp has_accumulation?(nil), do: false

  defp has_accumulation?(body) do
    AST.contains?(body, fn
      {{:., _, [{:__aliases__, _, mod}, func]}, _, _} ->
        Enum.any?(@accumulation_funcs, fn {m, fns} -> mod == m and func in fns end)
      _ -> false
    end)
  end

  defp has_cleanup?(nil), do: false

  defp has_cleanup?(body) do
    AST.contains?(body, fn
      {{:., _, [{:__aliases__, _, mod}, func]}, _, _} ->
        Enum.any?(@cleanup_funcs, fn {m, fns} -> mod == m and func in fns end)
      _ -> false
    end)
  end

  defp has_list_prepend?(nil), do: false

  defp has_list_prepend?(body) do
    AST.contains?(body, fn
      # [new | list] pattern in state update
      [{:|, _, _} | _] -> true
      _ -> false
    end)
  end

end
