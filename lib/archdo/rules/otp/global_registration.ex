defmodule Archdo.Rules.OTP.GlobalRegistration do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.26"

  @impl true
  def description, do: "No :global registration for local-only processes"

  @impl true
  def analyze(file, ast, _opts) do
    find_global_name_option(file, ast) ++ find_global_register(file, ast)
  end

  defp find_global_name_option(file, ast) do
    # {:global, ...} in name: option
    Enum.map(
      AST.find_all(ast, fn
        {:global, _meta, _} -> true
        _ -> false
      end),
      fn {_, meta, _} ->
        global_diag(file, meta, :name_option)
      end
    )
  end

  defp find_global_register(file, ast) do
    Enum.map(
      AST.find_all(ast, fn
        {{:., _, [:global, :register_name]}, _meta, _args} -> true
        _ -> false
      end),
      fn {_, meta, _} ->
        global_diag(file, meta, :register_call)
      end
    )
  end

  defp global_diag(file, meta, kind) do
    Diagnostic.info("5.26",
      title: ":global registration on local process",
      message:
        case kind do
          :name_option -> "Process registered via {:global, ...} name option"
          :register_call -> ":global.register_name/2 used to register a process"
        end,
      why:
        "`:global` uses distributed consensus across all connected nodes for every name registration and " <>
          "lookup. On a single node it's pure overhead vs local registry; on multiple nodes it creates " <>
          "contention and split-brain problems during netsplits, where two nodes can both decide they own " <>
          "the same name. Local processes shouldn't pay for cluster-wide coordination they don't need.",
      alternatives: [
        Fix.new(
          summary: "Use a local name (`name: __MODULE__`)",
          detail:
            "If only this node ever needs to find the process, register it with `name: __MODULE__` (or " <>
              "another atom). Lookup is O(1), no consensus, no netsplit risk.",
          applies_when: "The process is only accessed from one node."
        ),
        Fix.new(
          summary: "Use Registry with `:via` tuples for dynamic local naming",
          detail:
            "If the name is dynamic (one process per user/tenant), use `{:via, Registry, {MyApp.Registry, key}}` " <>
              "instead of building global atoms.",
          applies_when: "The name is dynamic but only relevant to one node."
        ),
        Fix.new(
          summary: "Switch to `:pg` or Horde for true cluster registration",
          detail:
            "If you genuinely need cluster-wide coordination, prefer `:pg` (process groups, built into OTP) or " <>
              "the `Horde` library. Both are designed for multi-node convergence with sane netsplit behaviour.",
          applies_when: "You really do need cluster-wide registration."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#5.26"],
      context: %{kind: kind},
      file: file,
      line: AST.line(meta)
    )
  end
end
