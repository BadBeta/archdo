defmodule Archdo.Rules.Module.IfElseDispatch do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.19"

  @impl true
  def description, do: "if/else used for structural dispatch — use multi-clause functions or case"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      find_if_else_dispatch(file, ast)
    end
  end

  defp find_if_else_dispatch(file, ast) do
    fns = AST.extract_functions(ast, :all)

    Enum.flat_map(fns, fn {name, arity, _meta, _args, body} ->
      find_dispatch_ifs(body, file, name, arity)
    end)
  end

  defp find_dispatch_ifs(nil, _file, _name, _arity), do: []

  defp find_dispatch_ifs(body, file, name, arity) do
    Enum.map(
      AST.find_all(body, fn
        # if/else with both branches returning values (not side-effect-only)
        {:if, _, [condition, [{:do, do_body}, {:else, else_body}]]} ->
          structural_dispatch?(condition) and
            both_return_values?(do_body, else_body)

        # if with is_* guard AND else branch — structural dispatch on type
        {:if, _, [{guard, _, _}, [{:do, _}, {:else, _}]]}
        when guard in [
               :is_map,
               :is_list,
               :is_binary,
               :is_struct,
               :is_atom,
               :is_integer,
               :is_nil,
               :is_float,
               :is_tuple
             ] ->
          true

        _ ->
          false
      end),
      fn {_, meta, _} ->
        build_diagnostic(file, name, arity, meta)
      end
    )
  end

  # Detects structural dispatch conditions:
  # - is_struct(x, Mod), is_map(x), is_list(x), is_binary(x)
  # - x != nil with else branch
  # - match?(pattern, x)
  # - Map.has_key?(x, :key)
  defp structural_dispatch?({guard, _, _})
       when guard in [
              :is_map,
              :is_list,
              :is_binary,
              :is_struct,
              :is_atom,
              :is_integer,
              :is_float,
              :is_tuple,
              :is_nil,
              :is_boolean,
              :is_number,
              :is_pid
            ] do
    true
  end

  defp structural_dispatch?({:!=, _, [_, {:__block__, _, [nil]}]}), do: true
  defp structural_dispatch?({:!=, _, [_, nil]}), do: true
  defp structural_dispatch?({:==, _, [_, {:__block__, _, [nil]}]}), do: true
  defp structural_dispatch?({:==, _, [_, nil]}), do: true
  defp structural_dispatch?({:match?, _, _}), do: true

  defp structural_dispatch?({{:., _, [{:__aliases__, _, [:Map]}, :has_key?]}, _, _}), do: true

  # Nested boolean: is_map(x) and Map.has_key?(x, :key)
  defp structural_dispatch?({:and, _, [left, right]}) do
    structural_dispatch?(left) or structural_dispatch?(right)
  end

  defp structural_dispatch?(_), do: false

  # Both branches return meaningful values (not just side effects)
  defp both_return_values?(do_body, else_body) do
    not is_nil(do_body) and not is_nil(else_body) and
      do_body != :ok and else_body != :ok
  end

  defp build_diagnostic(file, name, arity, meta) do
    Diagnostic.info("6.19",
      title: "if/else for structural dispatch",
      message: "#{name}/#{arity} uses if/else to dispatch on data shape — use pattern matching",
      why:
        "Elixir's multi-clause functions and case expressions handle structural dispatch " <>
          "more clearly than if/else chains. Pattern matching is exhaustive (the compiler warns " <>
          "on missing clauses), self-documenting (each clause shows the shape it handles), and " <>
          "extensible (add a clause, don't modify a condition). if/else hides the dispatch " <>
          "inside a boolean expression and doesn't compose.",
      alternatives: [
        Fix.new(
          summary: "Use multi-clause functions with pattern matching",
          detail:
            "```elixir\n" <>
              "# BAD\n" <>
              "def process(data) do\n" <>
              "  if is_map(data), do: handle_map(data), else: handle_other(data)\n" <>
              "end\n\n" <>
              "# GOOD\n" <>
              "def process(%{} = data), do: handle_map(data)\n" <>
              "def process(data), do: handle_other(data)\n" <>
              "```",
          applies_when: "The function dispatches on the argument's type or shape."
        ),
        Fix.new(
          summary: "Use case for single-value dispatch",
          detail:
            "If the dispatch is on a single value inside the function body, " <>
              "`case value do %{} -> ...; _ -> ... end` is clearer than if/else.",
          applies_when: "The dispatch is on a local variable, not a function argument."
        ),
        Fix.new(
          summary: "Use guards for type constraints",
          detail: "Move the type check to a guard: `def process(data) when is_map(data)`",
          applies_when: "The condition is a simple type guard."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.19"],
      context: %{function: "#{name}/#{arity}"},
      file: file,
      line: AST.line(meta)
    )
  end
end
