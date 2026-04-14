defmodule Archdo.Rules.OTP.AgentMisuse do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.3"

  @impl true
  def description, do: "Agent used as read-heavy cache — ETS would be faster"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.uses_agent?(ast) do
      false -> []
      true -> check_agent_usage(file, ast)
    end
  end

  defp check_agent_usage(file, ast) do
    module_name = AST.extract_module_name(ast)
    cache_name? = String.contains?(module_name, "Cache") or String.contains?(module_name, "Store")

    # Count Agent.get vs Agent.update calls in the module
    get_count = count_calls(ast, :get)
    update_count = count_calls(ast, :update) + count_calls(ast, :get_and_update)

    # Check for complex anonymous functions in Agent calls
    complex_fns? = has_complex_agent_fns?(ast)

    cond do
      cache_name? and get_count > update_count ->
        [read_heavy_diag(file, module_name, get_count, update_count)]

      complex_fns? ->
        [complex_callback_diag(file, module_name)]

      true ->
        []
    end
  end

  defp read_heavy_diag(file, module_name, get_count, update_count) do
    Diagnostic.info("5.3",
      title: "Agent used as read-heavy cache",
      message:
        "#{module_name} performs #{get_count} Agent.get calls vs #{update_count} updates — reads serialize through one process",
      why:
        "Agent serializes every operation: reads queue behind writes, and the anonymous function inside the " <>
          "Agent runs in the Agent's own process while the caller blocks. For a read-heavy cache that means " <>
          "every reader pays the cost of every concurrent reader, even though there's no contention on the data.",
      alternatives: [
        Fix.new(
          summary: "Replace the Agent with a public ETS table",
          detail:
            "Create the ETS table in the supervision tree (e.g. `:ets.new(:my_cache, [:set, :named_table, " <>
              ":public, read_concurrency: true])`) and access it directly from callers. Reads happen on the " <>
              "calling process with no message round-trip.",
          example: """
          ```elixir
          # in your supervisor's start/2:
          :ets.new(:my_cache, [:set, :named_table, :public, read_concurrency: true])

          # callers:
          def get(key), do: :ets.lookup(:my_cache, key)
          def put(key, val), do: :ets.insert(:my_cache, {key, val})
          ```
          """,
          applies_when: "The data is mostly read-only, or writes are infrequent enough not to need ordering."
        ),
        Fix.new(
          summary: "Use `:persistent_term` for almost-static configuration",
          detail:
            "If the cached data changes only at startup or rarely, `:persistent_term.put/2` and `get/1` give you " <>
              "lock-free reads with zero per-call overhead. Updates are expensive (full GC sweep) so reserve it for cold writes.",
          applies_when: "The data is configuration-like and updates are rare."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#5.3"],
      context: %{module: module_name, get_count: get_count, update_count: update_count},
      file: file,
      line: 1
    )
  end

  defp complex_callback_diag(file, module_name) do
    Diagnostic.info("5.3",
      title: "Complex logic inside Agent callback",
      message: "#{module_name} runs non-trivial logic inside an Agent.get/update anonymous function",
      why:
        "Anonymous functions passed to Agent run inside the Agent process. While they execute, every other " <>
          "caller is blocked on the Agent's mailbox. Heavy logic inside the callback turns the Agent into a " <>
          "serial bottleneck even when callers don't share data.",
      alternatives: [
        Fix.new(
          summary: "Move the logic outside the Agent and only mutate state inside",
          detail:
            "Compute the result on the caller, then call `Agent.update` with a tiny function that just stores " <>
              "the precomputed value. The Agent block becomes O(1) and other callers are unblocked.",
          applies_when: "The work doesn't need atomic visibility of the prior state."
        ),
        Fix.new(
          summary: "Promote the Agent to a GenServer with a richer protocol",
          detail:
            "If the logic genuinely needs the prior state and must be atomic, GenServer gives you call/cast " <>
              "with explicit message types and lets you split the work between the caller and the server.",
          applies_when: "The logic must be atomic against concurrent updates."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#5.3"],
      context: %{module: module_name},
      file: file,
      line: 1
    )
  end

  defp count_calls(ast, func_name) do
    AST.find_all(ast, fn
      {{:., _, [{:__aliases__, _, [:Agent]}, ^func_name]}, _, _} -> true
      _ -> false
    end)
    |> length()
  end

  defp has_complex_agent_fns?(ast) do
    AST.contains?(ast, fn
      {{:., _, [{:__aliases__, _, [:Agent]}, func]}, _, args}
      when func in [:get, :update, :get_and_update] ->
        Enum.any?(args, &complex_fn?/1)

      _ ->
        false
    end)
  end

  defp complex_fn?({:fn, _, [{:->, _, [_, body]}]}) do
    line_count = estimate_ast_size(body)
    line_count > 3
  end

  defp complex_fn?(_), do: false

  defp estimate_ast_size(ast) do
    {_, count} =
      Macro.prewalk(ast, 0, fn node, acc ->
        case node do
          {_, _, _} -> {node, acc + 1}
          _ -> {node, acc}
        end
      end)

    count
  end

end
