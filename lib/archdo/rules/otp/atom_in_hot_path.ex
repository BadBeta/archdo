defmodule Archdo.Rules.OTP.AtomInHotPath do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.44"

  @impl true
  def description, do: "String.to_atom in hot paths risks atom table exhaustion"

  @genserver_callbacks [:handle_call, :handle_cast, :handle_info]

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_atom_in_hot_path(file, ast)
    end
  end

  defp find_atom_in_hot_path(file, ast) do
    in_callbacks(file, ast) ++ in_enum_callbacks(file, ast)
  end

  defp in_callbacks(file, ast) do
    callbacks = AST.extract_callbacks(ast)

    for callback_name <- @genserver_callbacks,
        {_meta, _args, body} <- Map.get(callbacks, callback_name, []),
        body != nil,
        call <- find_string_to_atom(body),
        {_, call_meta, _} = call do
      build_diagnostic(file, call_meta, "GenServer.#{callback_name}")
    end
  end

  defp in_enum_callbacks(file, ast) do
    enum_calls = find_enum_with_to_atom(ast)
    for_calls = find_for_with_to_atom(ast)

    Enum.map(enum_calls ++ for_calls, fn {meta, context} ->
      build_diagnostic(file, meta, context)
    end)
  end

  defp find_enum_with_to_atom(ast) do
    ast
    |> AST.find_all(fn
      {{:., _, [{:__aliases__, _, [:Enum]}, fun]}, _, _}
      when fun in [:map, :reduce, :flat_map, :each, :filter] ->
        true

      _ ->
        false
    end)
    |> Enum.flat_map(fn {_, meta, args} = _node ->
      # The callback is typically the last argument
      callback = List.last(args)

      case has_string_to_atom?(callback) do
        true -> [{meta, "Enum callback"}]
        false -> []
      end
    end)
  end

  defp find_for_with_to_atom(ast) do
    ast
    |> AST.find_all(fn
      {:for, _, _} -> true
      _ -> false
    end)
    |> Enum.flat_map(fn {:for, meta, args} ->
      body = Keyword.get(List.last(args) || [], :do)

      case has_string_to_atom?(body) do
        true -> [{meta, "for comprehension"}]
        false -> []
      end
    end)
  end

  defp find_string_to_atom(ast) do
    AST.find_all(ast, fn
      {{:., _, [{:__aliases__, _, [:String]}, :to_atom]}, _, _} -> true
      _ -> false
    end)
  end

  defp has_string_to_atom?(nil), do: false

  defp has_string_to_atom?(ast) do
    AST.contains?(ast, fn
      {{:., _, [{:__aliases__, _, [:String]}, :to_atom]}, _, _} -> true
      _ -> false
    end)
  end

  defp build_diagnostic(file, meta, context) do
    Diagnostic.warning("5.44",
      title: "String.to_atom in hot path",
      message: "String.to_atom/1 called inside #{context} — atoms are never garbage collected",
      why:
        "The BEAM atom table has a hard limit (default ~1M entries) and atoms are never garbage " <>
          "collected. Calling String.to_atom/1 inside a GenServer callback or an Enum/for loop " <>
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
