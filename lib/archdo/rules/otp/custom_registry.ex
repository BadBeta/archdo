defmodule Archdo.Rules.OTP.CustomRegistry do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.25"

  @impl true
  def description, do: "Don't reinvent Registry — use Elixir's built-in Registry module"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.genserver_module?(ast) do
      false ->
        []

      true ->
        check_custom_registry(file, ast)
    end
  end

  defp check_custom_registry(file, ast) do
    module_name = AST.extract_module_name(ast)

    # Heuristic: module named *Registry* that is a GenServer but doesn't use Registry
    name_suggests_registry? =
      String.contains?(module_name, "Registry") or String.contains?(module_name, "Registrar")

    uses_builtin_registry? =
      AST.contains?(ast, fn
        {:__aliases__, _, [:Registry]} -> true
        _ -> false
      end)

    stores_pids? = stores_pids_in_state?(ast)

    if name_suggests_registry? and not uses_builtin_registry? and stores_pids? do
      [
        Diagnostic.info("5.25",
          title: "Hand-rolled process registry",
          message: "#{module_name} stores name → pid mappings in GenServer state",
          why:
            "Elixir's `Registry` already does this with concurrent reads, automatic deregistration when " <>
              "monitored processes die, and optional partitioning. A GenServer-based replacement serializes " <>
              "every lookup through one mailbox (becoming a bottleneck), has no automatic cleanup so dead " <>
              "pids accumulate, and reinvents wheels at the cost of correctness.",
          alternatives: [
            Fix.new(
              summary: "Replace the module with Registry in the supervision tree",
              detail:
                "Add `{Registry, keys: :unique, name: MyApp.Registry}` to the supervision tree and use " <>
                  "`{:via, Registry, {MyApp.Registry, key}}` when starting the registered processes. Look-ups " <>
                  "happen on the calling process via ETS — no GenServer round-trip — and dead pids are removed " <>
                  "automatically when their monitor fires.",
              example: """
              ```elixir
              # supervision tree:
              {Registry, keys: :unique, name: MyApp.Registry}

              # at start time:
              GenServer.start_link(__MODULE__, args, name: {:via, Registry, {MyApp.Registry, key}})

              # lookups:
              [{pid, _}] = Registry.lookup(MyApp.Registry, key)
              ```
              """,
              applies_when: "The registry is local to one node."
            ),
            Fix.new(
              summary: "Use `:pg` or Horde for distributed registration",
              detail:
                "If the registry must span nodes, use `:pg` (process groups) or the `Horde.Registry` library, " <>
                  "both of which are designed for multi-node coordination and provide proper convergence semantics.",
              applies_when: "The registry must work across a cluster."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#5.25"],
          context: %{module: module_name},
          file: file,
          line: 1
        )
      ]
    else
      []
    end
  end

  defp stores_pids_in_state?(ast) do
    callbacks = AST.extract_callbacks(ast)
    Enum.any?([:handle_call, :handle_cast, :handle_info], &any_pid_clause?(&1, callbacks))
  end

  defp any_pid_clause?(cb, callbacks) do
    Enum.any?(callbacks[cb] || [], &clause_stores_pid?/1)
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # the body's nil-vs-AST shape.
  defp clause_stores_pid?({_, _, nil}), do: false

  defp clause_stores_pid?({_, _, body}) do
    AST.contains?(body, &pid_node?/1)
  end

  defp pid_node?({:pid, _, nil}), do: true
  defp pid_node?({:pid, _, ctx}) when is_atom(ctx), do: true
  defp pid_node?(_), do: false
end
