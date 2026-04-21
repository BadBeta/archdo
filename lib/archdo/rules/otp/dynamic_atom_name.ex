defmodule Archdo.Rules.OTP.DynamicAtomName do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.24"

  @impl true
  def description, do: "No dynamic atom creation for process names"

  @impl true
  def analyze(file, ast, _opts) do
    find_string_to_atom(file, ast) ++ find_atom_interpolation(file, ast)
  end

  defp find_string_to_atom(file, ast) do
    Enum.map(AST.find_all(ast, fn
      # String.to_atom(...)
      {{:., _, [{:__aliases__, _, [:String]}, :to_atom]}, _meta, _args} -> true
      _ -> false
    end), fn {_, meta, _} ->
      Diagnostic.info("5.24",
        title: "Dynamic atom from String.to_atom",
        message: "String.to_atom/1 is called — atoms are never garbage collected",
        why:
          "Atoms live in a global table with a hard limit (default 1,048,576). Anything that converts user " <>
            "input or growing strings to atoms is a leak: enough unique inputs and the VM crashes with " <>
            "system_limit. It's a well-known DoS vector and the Elixir anti-patterns guide flags it explicitly. " <>
            "When used for process names it also makes Registry's safe lookup unavailable.",
        alternatives: [
          Fix.new(
            summary: "Use Registry with `:via` tuples for dynamic process naming",
            detail:
              "Replace dynamic atom names with `{:via, Registry, {MyApp.Registry, key}}`. Registry handles the " <>
                "name → pid mapping with safe term keys (no atom table pressure) and automatic cleanup on death.",
            example: """
            ```elixir
            def start_link(user_id) do
              name = {:via, Registry, {MyApp.Registry, {:session, user_id}}}
              GenServer.start_link(__MODULE__, user_id, name: name)
            end
            ```
            """,
            applies_when: "The atom is used to name a process."
          ),
          Fix.new(
            summary: "Switch to String.to_existing_atom/1",
            detail:
              "If the input must already correspond to a known atom (e.g. validating an enum), use " <>
                "`String.to_existing_atom/1`. It only succeeds for atoms the VM has already seen, so untrusted " <>
                "input cannot create new entries in the atom table.",
            applies_when: "The set of valid atoms is fixed at compile time."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#5.24"],
        context: %{kind: :string_to_atom},
        file: file,
        line: AST.line(meta)
      )
    end)
  end

  defp find_atom_interpolation(file, ast) do
    # Detect :"prefix_#{variable}" patterns
    Enum.map(AST.find_all(ast, fn
      # Sigil-style atom with interpolation: :"foo_#{bar}"
      {:"::", _meta, [{{:., _, [Kernel, :to_string]}, _, _}, {:atom, _, _}]} -> true
      _ -> false
    end), fn {_, meta, _} ->
      Diagnostic.info("5.24",
        title: "Dynamic atom from interpolation",
        message: "Atom is constructed via interpolation (`:\"prefix_\#{variable}\"`)",
        why:
          "Atom interpolation creates a new atom on every call. Atoms live forever — given enough unique " <>
            "inputs the global atom table fills up (default cap: 1,048,576) and the VM crashes. Even before " <>
            "that, the leak inflates RAM and confuses observability tooling.",
        alternatives: [
          Fix.new(
            summary: "Use Registry with `:via` tuples instead of building atoms",
            detail:
              "If the goal is to look up a process by a dynamic key, register it under `{:via, Registry, " <>
                "{MyApp.Registry, key}}` where key is a normal term (string, integer, tuple). No atom is created " <>
                "and Registry handles cleanup on death.",
            applies_when: "The atom names a process or a known table."
          ),
          Fix.new(
            summary: "Keep the dynamic value as a string or tuple in your own data structures",
            detail:
              "Most code that builds atoms only does so out of habit. A Map keyed by string or tuple does the " <>
                "same job with no atom-table pressure.",
            applies_when: "The atom is used as a map key or identifier, not a process name."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#5.24"],
        context: %{kind: :interpolation},
        file: file,
        line: AST.line(meta)
      )
    end)
  end
end
