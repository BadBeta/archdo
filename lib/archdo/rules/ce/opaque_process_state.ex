defmodule Archdo.Rules.CE.OpaqueProcessState do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-29. Long-running stateful processes
  # whose state cannot be inspected at runtime: no `format_status/1`
  # callback, no `:sys.get_state`-friendly state, no `Inspect`
  # derivation. Debugging requires tracing or restarts; runbooks
  # become guess-and-check.

  alias Archdo.{AST, Diagnostic, Fix}

  @stateful_uses [GenServer, Agent, [:GenServer], [:Agent]]
  @stateful_behaviours [:gen_statem, :gen_event, :gen_server]

  @impl true
  def id, do: "CE-29"

  @impl true
  def description,
    do: "Long-running stateful process module without an inspection hook (format_status/1)"

  @impl true
  def analyze(file, ast, _opts) do
    cond do
      AST.test_file?(file) -> []
      not stateful?(ast) -> []
      AST.has_marker?(ast, :archdo_opaque_state) -> []
      defines_format_status?(ast) -> []
      true -> [build_diagnostic(file, ast)]
    end
  end

  defp stateful?(ast) do
    AST.contains?(ast, fn
      {:use, _, [{:__aliases__, _, parts}]} when is_list(parts) -> parts in @stateful_uses
      {:use, _, [{:__aliases__, _, parts}, _opts]} when is_list(parts) -> parts in @stateful_uses
      {:use, _, [mod]} when is_atom(mod) -> mod in @stateful_uses
      {:@, _, [{:behaviour, _, [behaviour]}]} -> behaviour in @stateful_behaviours
      _ -> false
    end)
  end

  defp defines_format_status?(ast) do
    ast
    |> AST.extract_functions(:public)
    |> Enum.any?(fn {name, arity, _, _, _} ->
      name == :format_status and arity in [1, 2]
    end)
  end

  defp build_diagnostic(file, ast) do
    module = AST.extract_module_name(ast)

    Diagnostic.warning("CE-29",
      title: "Process state without inspection hook",
      message:
        "#{module}: stateful process module (use GenServer/Agent or @behaviour " <>
          ":gen_statem) without `format_status/1` — state is opaque to " <>
          "`:sys.get_state`, debugging requires tracing or restarts",
      why:
        "Long-running stateful processes that hold opaque state force operators " <>
          "into reactive debugging: trace, reproduce, or restart. `format_status/1` " <>
          "exposes a sanitized view that runbooks can rely on. For state holding " <>
          "PII or secrets, lacking the hook also risks leaking via " <>
          "`:sys.get_state` and observer outputs.",
      alternatives: [
        Fix.new(
          summary: "Implement format_status/1 returning a sanitized state view",
          detail:
            "Define `def format_status(%{state: state})` returning a map with " <>
              "the operationally useful fields (queue depth, last activity, " <>
              "session count) and any sensitive fields scrubbed.",
          applies_when: "The state has fields useful for ops introspection."
        ),
        Fix.new(
          summary: "Add @derive {Inspect, except: [...]} on the state struct",
          detail:
            "If the state is a struct, declare `@derive {Inspect, except: " <>
              "[:secret_token, :pii]}` so `:sys.get_state` and observer cannot " <>
              "print sensitive fields.",
          applies_when: "The state struct contains sensitive fields."
        ),
        Fix.new(
          summary: "Mark @archdo_opaque_state if intentional",
          detail:
            "If the process genuinely must remain opaque (operator runs with " <>
              "elevated access; runbook says 'do not introspect'), declare it: " <>
              "`@archdo_opaque_state \"reason\"` at module level.",
          applies_when: "Opacity is a deliberate choice."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-29"],
      context: %{module: module},
      file: file,
      line: 1
    )
  end
end
