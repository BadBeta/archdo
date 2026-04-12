defmodule Archdo.Rules.Module.TypeDispatch do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "4.3"

  @impl true
  def description, do: "Type-dispatching case statements suggest missing polymorphism"

  @impl true
  def analyze(file, ast, _opts) do
    find_type_dispatch_patterns(file, ast)
  end

  defp find_type_dispatch_patterns(file, ast) do
    fns = AST.extract_functions(ast, :all)

    fns
    |> Enum.flat_map(fn {name, arity, _meta, _args, body} ->
      find_atom_dispatch_cases(file, body, name, arity)
    end)
  end

  defp find_atom_dispatch_cases(_file, nil, _name, _arity), do: []

  defp find_atom_dispatch_cases(file, body, fn_name, fn_arity) do
    AST.find_all(body, fn
      {:case, _meta, [_expr, [do: clauses]]} when is_list(clauses) ->
        # Count clauses that match on bare atoms (not :ok/:error/true/false)
        atom_clauses = count_atom_dispatch_clauses(clauses)
        atom_clauses >= 4

      _ ->
        false
    end)
    |> Enum.map(fn {:case, meta, [_expr, [do: clauses]]} ->
      atom_count = count_atom_dispatch_clauses(clauses)

      Diagnostic.info("4.3",
        title: "Type-dispatching case statement",
        message: "case in #{fn_name}/#{fn_arity} dispatches on #{atom_count} distinct type atoms",
        why:
          "When a case matches on `:foo`, `:bar`, `:baz` to pick which code path to run, the case is " <>
            "implementing manual polymorphism. Adding a new type means editing every case dispatch in the " <>
            "codebase — exactly the change-amplification problem behaviours and protocols solve. The case " <>
            "violates Open/Closed: adding a type shouldn't require modifying existing functions.",
        alternatives: [
          Fix.new(
            summary: "Use multi-clause functions and dispatch on the first arg",
            detail:
              "Replace `case type do` with multiple `def fun(:foo, ...), def fun(:bar, ...)` clauses. Each " <>
                "type's behaviour lives next to its dispatch tag and adding a type means adding a clause, " <>
                "not editing existing logic.",
            applies_when: "The dispatch is on a small, fixed-ish set of types in one module."
          ),
          Fix.new(
            summary: "Define a behaviour and one impl module per type",
            detail:
              "If the dispatch hides genuinely different logic per type, define a behaviour with the relevant " <>
                "callbacks and put each branch in its own module. Routes through a `Map.get(@impls, type)` " <>
                "lookup or a single dispatch function.",
            applies_when: "Each branch is substantial and the type set may grow."
          ),
          Fix.new(
            summary: "Use a Protocol if the dispatch is on struct types",
            detail:
              "If the case is matching on `%FooStruct{}` vs `%BarStruct{}`, that's exactly what protocols " <>
                "are for. Define a protocol with the operation, implement it for each struct type, and call " <>
                "the protocol function instead.",
            applies_when: "The dispatch is on struct types rather than atoms."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#4.3"],
        context: %{function: "#{fn_name}/#{fn_arity}", branch_count: atom_count},
        file: file,
        line: AST.line(meta)
      )
    end)
  end

  defp count_atom_dispatch_clauses(clauses) do
    Enum.count(clauses, fn
      {:->, _, [[atom | _] | _]} when is_atom(atom) ->
        atom not in [true, false, nil, :ok, :error, :_, :else]

      {:->, _, [[{:__block__, _, [atom]} | _] | _]} when is_atom(atom) ->
        atom not in [true, false, nil, :ok, :error, :_, :else]

      _ ->
        false
    end)
  end
end
