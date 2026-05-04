defmodule Archdo.Rules.CE.VolatileCallNoTimeout do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-34. Sharper version of 4.18 — uses
  # the Volatility classification rather than a hard-coded HTTP-client
  # list. Fires per call site when:
  #   * the module is `:volatile`-tagged AND
  #   * the call target supports a timeout option (per the table below)
  #     AND none is provided
  #
  # `GenServer.call/2` (no third arg → implicit 5s default) is the
  # special case — flagged regardless of host module's volatility,
  # because the implicit-timeout problem is intrinsic to the API
  # shape.
  #
  # Default timeout-key table; project overrides via `.archdo.exs`
  # `volatile_timeout_keys` will be added when a real consumer needs
  # them.

  alias Archdo.{AST, Diagnostic, Fix, Volatility}

  @volatile_tag :volatile

  @impl true
  def id, do: "CE-34"

  @impl true
  def description,
    do: "Volatile call without explicit timeout option (uses Volatility classification)"

  # For each HTTP client, the keys list the timeout options the rule
  # will accept as evidence the call is bounded, and the calls list
  # names ONLY the functions that actually make a network request.
  # Builder/configurator calls (`Req.new`, `Finch.build`, `Tesla.client`)
  # don't make a request, so the timeout-option check doesn't apply.
  @http_methods [:get, :post, :put, :patch, :delete, :head, :options, :request, :run]

  @timeout_specs %{
    [:Tesla] => %{
      keys: [:timeout, :recv_timeout, :receive_timeout],
      calls: @http_methods
    },
    [:Req] => %{
      keys: [:receive_timeout, :pool_timeout, :connect_options],
      calls: @http_methods
    },
    [:Finch] => %{
      keys: [:receive_timeout, :pool_timeout],
      calls: [:request, :stream, :stream_while]
    },
    [:HTTPoison] => %{
      keys: [:timeout, :recv_timeout],
      calls: @http_methods
    }
  }

  @impl true
  def analyze(file, ast, opts) do
    classification = Volatility.classification_for(file, ast, opts)

    httpish_findings =
      case classification.tag == @volatile_tag do
        true -> find_unbounded_http(file, ast)
        false -> []
      end

    # GenServer.call/2 is flagged regardless of host volatility — the
    # implicit-timeout problem is intrinsic to that API shape.
    httpish_findings ++ find_unbounded_genserver_call(file, ast)
  end

  # --- HTTP client calls ---

  defp find_unbounded_http(file, ast) do
    calls =
      AST.find_all(ast, fn
        {{:., _, [{:__aliases__, _, mod_parts}, fun]}, _, _} when is_atom(fun) ->
          http_calling?(mod_parts, fun)

        _ ->
          false
      end)

    Enum.flat_map(calls, fn
      {{:., _, [{:__aliases__, _, mod_parts}, fun]}, meta, args} ->
        keys = @timeout_specs |> Map.get(mod_parts, %{keys: []}) |> Map.fetch!(:keys)

        case has_timeout_option?(args, keys) do
          true ->
            []

          false ->
            target = Enum.map_join(mod_parts, ".", &Atom.to_string/1)
            [build_http_diagnostic(file, AST.line(meta), target, fun, keys)]
        end

      _ ->
        []
    end)
  end

  # The call is HTTP-making (vs. config / builder) when the module is
  # in @timeout_specs AND the function name is in that module's
  # documented call list.
  defp http_calling?(mod_parts, fun) do
    case Map.get(@timeout_specs, mod_parts) do
      %{calls: calls} -> fun in calls
      _ -> false
    end
  end

  defp has_timeout_option?(args, keys) do
    case List.last(args) do
      list when is_list(list) and list != [] -> keyword_has_any?(list, keys)
      {:__block__, _, [list]} when is_list(list) and list != [] -> keyword_has_any?(list, keys)
      _ -> false
    end
  end

  defp keyword_has_any?(opts, keys) do
    Enum.any?(opts, &pair_matches?(&1, keys))
  end

  defp pair_matches?({key, value}, keys) when is_atom(key) do
    key in keys or recurse_into(value, keys)
  end

  defp pair_matches?({{:__block__, _, [key]}, value}, keys) when is_atom(key) do
    key in keys or recurse_into(value, keys)
  end

  defp pair_matches?(_, _), do: false

  defp recurse_into(value, keys) when is_list(value), do: keyword_has_any?(value, keys)

  defp recurse_into({:__block__, _, [list]}, keys) when is_list(list),
    do: keyword_has_any?(list, keys)

  defp recurse_into(_, _), do: false

  # --- GenServer.call ---

  defp find_unbounded_genserver_call(file, ast) do
    calls =
      AST.find_all(ast, fn
        {{:., _, [{:__aliases__, _, [:GenServer]}, :call]}, _, [_, _]} -> true
        _ -> false
      end)

    Enum.map(calls, fn {_, meta, _} ->
      build_genserver_diagnostic(file, AST.line(meta))
    end)
  end

  # --- diagnostics ---

  defp build_http_diagnostic(file, line, target, fun, keys) do
    keys_str = Enum.map_join(keys, " or ", &":#{&1}")

    Diagnostic.warning("CE-34",
      title: "Volatile call without explicit timeout",
      message: "#{target}.#{fun}() called without #{keys_str} — vendor default may be infinite",
      why:
        "Default timeouts on HTTP clients are often generous (30s+) or unbounded. " <>
          "Under load or downstream degradation, callers stack up waiting. Explicit " <>
          "timeouts let you fail fast, shed load, and give callers a chance to " <>
          "retry or degrade.",
      alternatives: [
        Fix.new(
          summary: "Add an explicit timeout option",
          detail:
            "Pass `[#{hd(keys)}: 5_000]` (or appropriate value) in the options. " <>
              "Cascade timeouts with the surrounding GenServer.call and " <>
              "endpoint-level timeouts (outer > middle > inner).",
          applies_when: "Always — explicit timeouts are a production-readiness baseline."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-34"],
      context: %{target: target, function: fun},
      file: file,
      line: line
    )
  end

  defp build_genserver_diagnostic(file, line) do
    Diagnostic.info("CE-34",
      title: "GenServer.call/2 without explicit timeout (implicit 5s)",
      message:
        "GenServer.call/2 uses the implicit 5s timeout — make it explicit to " <>
          "document the SLA and avoid surprise timeouts under load",
      why:
        "The default 5s GenServer.call timeout is often wrong: too short for " <>
          "long-running operations, too long for hot-path requests. Explicit " <>
          "timeouts document the expected response time and make debugging " <>
          "TimeoutError easier.",
      alternatives: [
        Fix.new(
          summary: "Add an explicit timeout as the third argument",
          detail: "`GenServer.call(pid, msg, 10_000)` with a value matched to the operation.",
          applies_when: "The GenServer performs I/O or non-trivial computation."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-34"],
      context: %{},
      file: file,
      line: line
    )
  end
end
