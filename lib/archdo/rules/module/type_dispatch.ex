defmodule Archdo.Rules.Module.TypeDispatch do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "4.3"

  @impl true
  def description, do: "Type-dispatching case statements suggest missing polymorphism"

  @ignored_atoms [:ok, :error, true, false, nil]

  @impl true
  def analyze(file, ast, _opts) do
    find_type_dispatch_patterns(file, ast)
  end

  defp find_type_dispatch_patterns(file, ast) do
    fns = AST.extract_functions(ast, :all)

    case_dispatch =
      Enum.flat_map(fns, fn {name, arity, _meta, _args, body} ->
        find_atom_dispatch_cases(file, body, name, arity)
      end)

    clause_dispatch = find_multi_clause_dispatch(file, ast)

    case_dispatch ++ clause_dispatch
  end

  defp find_atom_dispatch_cases(_file, nil, _name, _arity), do: []

  defp find_atom_dispatch_cases(file, body, fn_name, fn_arity) do
    Enum.map(
      AST.find_all(body, fn
        {:case, _meta, [_expr, [do: clauses]]} when is_list(clauses) ->
          # Count clauses that match on bare atoms (not :ok/:error/true/false)
          atom_clauses = count_atom_dispatch_clauses(clauses)
          atom_clauses >= 4

        _ ->
          false
      end),
      fn {:case, meta, [_expr, [do: clauses]]} ->
        atom_count = count_atom_dispatch_clauses(clauses)

        Diagnostic.info("4.3",
          title: "Type-dispatching case statement",
          message:
            "case in #{fn_name}/#{fn_arity} dispatches on #{atom_count} distinct type atoms",
          why:
            "When a case matches on `:foo`, `:bar`, `:baz` to pick which code path to run, the case is " <>
              "implementing manual polymorphism. Adding a new type means editing every case dispatch in the " <>
              "codebase — exactly the change-amplification problem behaviours and protocols solve. The case " <>
              "violates Open/Closed: adding a type shouldn't require modifying existing functions.",
          alternatives: [
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
      end
    )
  end

  # --- Multi-clause function dispatch ---
  # Detects: def handle(:foo, data), def handle(:bar, data), ...
  # where 4+ clauses each match a distinct atom as the first argument.

  defp find_multi_clause_dispatch(file, ast) do
    # Collect all def/defp clauses grouped by {name, arity}
    {_, clauses_by_fn} =
      Macro.prewalk(ast, %{}, fn
        {kind, meta, [{name, _, args} | _]} = node, acc
        when kind in [:def, :defp] and is_atom(name) and is_list(args) ->
          key = {name, length(args)}
          entry = %{atom: first_arg_atom(args), line: AST.line(meta)}
          {node, Map.update(acc, key, [entry], &[entry | &1])}

        node, acc ->
          {node, acc}
      end)

    Enum.flat_map(clauses_by_fn, fn {{name, arity}, entries} ->
      entries = Enum.reverse(entries)

      distinct =
        for %{atom: atom} <- entries,
            atom != nil,
            atom not in @ignored_atoms,
            uniq: true,
            do: atom

      if match?([_, _, _, _ | _], distinct) and not genserver_callback?(name) do
        first_line = Enum.min_by(entries, & &1.line).line

        [
          Diagnostic.info("4.3",
            title: "Multi-clause type dispatch function",
            message:
              "#{name}/#{arity} has #{length(distinct)} clauses dispatching on atom types: " <>
                "#{Enum.map_join(Enum.take(distinct, 5), ", ", &inspect/1)}" <>
                case match?([_, _, _, _, _, _ | _], distinct) do
                  true -> ", ..."
                  false -> ""
                end,
            why:
              "When a function has many clauses each matching a different atom as the first argument, " <>
                "adding a new type requires editing this module. This violates Open/Closed — the module " <>
                "is open to modification when it should be closed. Each atom branch is effectively a " <>
                "manual vtable that should be a behaviour or protocol dispatch.",
            alternatives: [
              Fix.new(
                summary: "Define a behaviour and one module per type",
                detail:
                  "Extract the callback contract, create one module per type atom that implements it, " <>
                    "and dispatch via a map lookup or `Application.compile_env`. Adding a new type means " <>
                    "adding a new module, not editing existing clauses.",
                applies_when: "Each clause has substantial logic and the type set may grow."
              ),
              Fix.new(
                summary: "Use a map of atoms to functions",
                detail:
                  "Replace the multi-clause dispatch with `@handlers %{foo: &handle_foo/1, ...}` " <>
                    "and call `Map.fetch!(@handlers, type).(data)`. New types register in the map " <>
                    "without touching existing handler code.",
                applies_when: "The handlers are small and a full behaviour is overkill."
              ),
              Fix.new(
                summary: "Keep if the type set is genuinely fixed",
                detail:
                  "If the atoms represent a closed, stable set (e.g., HTTP methods, weekdays), " <>
                    "multi-clause dispatch is idiomatic and the OCP concern doesn't apply.",
                applies_when: "The set of types is fixed by an external standard."
              )
            ],
            references: ["ARCHITECTURE_RULES.md#4.3"],
            context: %{function: "#{name}/#{arity}", branch_count: length(distinct)},
            file: file,
            line: first_line
          )
        ]
      else
        []
      end
    end)
  end

  # GenServer callbacks naturally dispatch on message atoms — not an OCP violation.
  @genserver_callbacks ~w(handle_call handle_cast handle_info handle_continue)a
  defp genserver_callback?(name), do: name in @genserver_callbacks

  # Extract the atom from the first argument of a function clause, if it's a literal atom.
  defp first_arg_atom([atom | _]) when is_atom(atom), do: atom
  defp first_arg_atom([{:__block__, _, [atom]} | _]) when is_atom(atom), do: atom
  defp first_arg_atom(_), do: nil

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
