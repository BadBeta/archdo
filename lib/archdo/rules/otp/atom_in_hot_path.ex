defmodule Archdo.Rules.OTP.AtomInHotPath do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Rules.Helpers.LoopDetection

  @impl true
  def id, do: "5.44"

  @impl true
  def description, do: "String.to_atom in hot paths risks atom table exhaustion"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_atom_in_hot_path(file, ast)
    end
  end

  defp find_atom_in_hot_path(file, ast) do
    predicate = fn
      {{:., _, [{:__aliases__, _, [:String]}, :to_atom]}, _, _} -> true
      _ -> false
    end

    # Check all loops (Enum, Stream, :lists, for, receive, Task.async_stream)
    loop_hits =
      Enum.map(LoopDetection.find_in_loops(ast, predicate), fn {_, meta} ->
        build_diagnostic(file, meta, "loop body")
      end)

    # Check GenServer callbacks
    genserver_hits =
      Enum.map(LoopDetection.find_in_genserver_callbacks(ast, predicate), fn {_, meta} ->
        build_diagnostic(file, meta, "GenServer callback")
      end)

    # Check recursive functions
    recursion_hits =
      Enum.map(LoopDetection.find_in_recursive_fns(ast, predicate), fn {_, meta} ->
        build_diagnostic(file, meta, "recursive function")
      end)

    loop_hits ++ genserver_hits ++ recursion_hits
  end

  defp build_diagnostic(file, meta, context) do
    Diagnostic.warning("5.44",
      title: "String.to_atom in hot path",
      message: "String.to_atom/1 called inside #{context} — atoms are never garbage collected",
      why:
        "The BEAM atom table has a hard limit (default ~1M entries) and atoms are never garbage " <>
          "collected. Calling String.to_atom/1 inside a GenServer callback or a loop " <>
          "means every incoming message or collection element can create a new atom. Under load " <>
          "this exhausts the atom table and crashes the VM with :system_limit.",
      alternatives: [
        Fix.new(
          summary: "Use String.to_existing_atom/1 instead",
          detail:
            "If the set of valid atoms is known at compile time, use String.to_existing_atom/1. " <>
              "It only succeeds for atoms the VM has already seen, so untrusted input cannot " <>
              "create new entries in the atom table.",
          applies_when: "The set of valid atoms is fixed."
        ),
        Fix.new(
          summary: "Keep the value as a string or use a map for lookup",
          detail:
            "Most code that converts strings to atoms does so out of habit. A Map keyed by " <>
              "string does the same job with no atom-table pressure. If you need atoms for " <>
              "pattern matching, define an explicit allowlist with a case/cond.",
          applies_when: "The atom is used as a key or identifier."
        ),
        Fix.new(
          summary: "Move the atom conversion outside the hot path",
          detail:
            "If the conversion is genuinely needed, do it once at the boundary (e.g. during " <>
              "input parsing at startup) rather than on every message or iteration.",
          applies_when: "The atom creation can be hoisted to initialization."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#5.44"],
      context: %{hot_path: context},
      file: file,
      line: AST.line(meta)
    )
  end
end
