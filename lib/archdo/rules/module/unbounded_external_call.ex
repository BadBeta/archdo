defmodule Archdo.Rules.Module.UnboundedExternalCall do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — operational layer carve-out via Archdo.Phoenix.
  # Mix tasks and release scripts run once at the system entry point; an
  # implicit timeout there is fine — there's no caller stack to back up.

  alias Archdo.{AST, Diagnostic, Fix, Phoenix}

  @impl true
  def id, do: "4.18"

  @impl true
  def description, do: "External calls should have explicit timeouts"

  # HTTP client modules and their timeout option keys
  @http_clients %{
    [:HTTPoison] => [:timeout, :recv_timeout],
    [:Req] => [:receive_timeout, :connect_options],
    [:Finch] => [:receive_timeout]
  }

  @http_methods ~w(get post put patch delete head options request)a

  @impl true
  def analyze(file, ast, opts) do
    classification =
      case Keyword.get(opts, :phoenix) do
        %{layer: _} = c -> c
        _ -> Phoenix.classify_file(file, ast)
      end

    case AST.test_file?(file) or Phoenix.operational?(classification) do
      true -> []
      false -> find_unbounded_http(file, ast) ++ find_unbounded_genserver_call(file, ast)
    end
  end

  defp find_unbounded_http(file, ast) do
    calls =
      AST.find_all(ast, fn
        {{:., _, [{:__aliases__, _, mod_parts}, func]}, _, _} ->
          Map.has_key?(@http_clients, mod_parts) and base_func(func) in @http_methods

        _ ->
          false
      end)

    for {{:., _, [{:__aliases__, _, mod_parts}, func]}, meta, args} <- calls,
        timeout_keys = Map.get(@http_clients, mod_parts, []),
        not has_timeout_option?(args, timeout_keys) do
      service = Enum.map_join(mod_parts, ".", &to_string/1)
      keys_str = Enum.map_join(timeout_keys, " or ", &":#{&1}")

      Diagnostic.warning("4.18",
        title: "External call without explicit timeout",
        message: "#{service}.#{func}() called without #{keys_str} option",
        why:
          "HTTP clients default to generous timeouts (often 30s). Under load or when " <>
            "the remote service is degraded, callers stack up waiting. Explicit timeouts " <>
            "let you fail fast, shed load, and give callers a chance to retry or degrade.",
        alternatives: [
          Fix.new(
            summary: "Add an explicit timeout option",
            detail:
              "Add `#{hd(timeout_keys)}: 5_000` (or appropriate value) to the options. " <>
                "Example: `#{service}.#{func}(url, [], #{hd(timeout_keys)}: 5_000)`.",
            applies_when: "Always — explicit timeouts are a production best practice."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#4.18"],
        context: %{service: service, function: func},
        file: file,
        line: AST.line(meta)
      )
    end
  end

  defp find_unbounded_genserver_call(file, ast) do
    ast
    |> AST.find_all(fn
      {{:., _, [{:__aliases__, _, [:GenServer]}, :call]}, _, [_, _]} ->
        true

      _ ->
        false
    end)
    |> Enum.map(fn {{:., _, _}, meta, _} ->
      Diagnostic.info("4.18",
        title: "GenServer.call without explicit timeout",
        message: "GenServer.call/2 uses implicit 5s timeout — consider making it explicit",
        why:
          "The default 5s timeout is often fine, but making it explicit documents the " <>
            "expected response time and makes debugging timeout errors easier. For calls " <>
            "to external services or heavy operations, 5s may be too short or too long.",
        alternatives: [
          Fix.new(
            summary: "Add an explicit timeout as the third argument",
            detail:
              "Change `GenServer.call(pid, msg)` to `GenServer.call(pid, msg, 10_000)` " <>
                "with an appropriate timeout for the operation.",
            applies_when: "The GenServer performs I/O or heavy computation."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#4.18"],
        context: %{},
        file: file,
        line: AST.line(meta)
      )
    end)
  end

  defp has_timeout_option?(args, keys) do
    # The last arg in HTTP client calls is often a keyword list of options
    case List.last(args) do
      opts when is_list(opts) and opts != [] -> keyword_has_any?(opts, keys)
      _ -> false
    end
  end

  defp keyword_has_any?(opts, keys) do
    Enum.any?(opts, fn
      {key, _} when is_atom(key) ->
        key in keys

      {{:__block__, _, [key]}, _} when is_atom(key) ->
        key in keys

      # Check nested keyword (hackney: [recv_timeout: ...])
      {parent_key, nested} when is_atom(parent_key) and is_list(nested) ->
        keyword_has_any?(nested, keys)

      _ ->
        false
    end)
  end

  # Strip bang suffix to get base method name
  defp base_func(func) do
    func
    |> to_string()
    |> String.trim_trailing("!")
    |> String.to_existing_atom()
  end
end
