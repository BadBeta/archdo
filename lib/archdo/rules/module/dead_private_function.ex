defmodule Archdo.Rules.Module.DeadPrivateFunction do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.34"

  @impl true
  def description, do: "Private function is never called within its module"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_dead_privates(file, ast)
    end
  end

  defp find_dead_privates(file, ast) do
    private_fns = AST.extract_functions(ast, :private)
    private_defs = unique_private_defs(private_fns)
    call_set = collect_calls(ast)

    private_defs
    |> Enum.reject(&skip_function?/1)
    |> Enum.reject(fn {name, arity} ->
      # Direct call matches arity exactly.
      # Pipe call has arity - 1 (the pipe provides the first argument).
      MapSet.member?(call_set, {name, arity}) or
        (arity > 0 and MapSet.member?(call_set, {name, arity - 1}))
    end)
    |> Enum.map(fn {name, arity} ->
      meta = find_meta(private_fns, name, arity)
      build_diagnostic(file, AST.line(meta), name, arity)
    end)
  end

  defp unique_private_defs(private_fns) do
    private_fns
    |> Enum.map(fn {name, arity, _meta, _args, _body} -> {name, arity} end)
    |> Enum.uniq()
  end

  defp find_meta(private_fns, name, arity) do
    case Enum.find(private_fns, fn {n, a, _m, _args, _body} -> n == name and a == arity end) do
      {_, _, meta, _, _} -> meta
      nil -> []
    end
  end

  defp skip_function?({:when, _arity}), do: true

  defp skip_function?({name, _arity}) do
    name_str = Atom.to_string(name)
    (String.starts_with?(name_str, "__") and String.ends_with?(name_str, "__")) or
      String.starts_with?(name_str, "sigil_")
  end

  # Collect all function calls from function bodies only (not definition heads).
  # We extract all function bodies first, then walk each body for bare calls.
  defp collect_calls(ast) do
    all_fns = AST.extract_functions(ast, :all)

    Enum.reduce(all_fns, MapSet.new(), fn {_name, _arity, _meta, _args, body}, acc ->
      collect_calls_in_body(body, acc)
    end)
  end

  defp collect_calls_in_body(body, acc) do
    {_, calls} =
      Macro.prewalk(body, acc, fn
        # Function capture: &foo/N => {:&, _, [{:/, _, [{:foo, _, _}, N]}]}
        {:&, _, [{:/, _, [{name, _, _}, arity]}]} = node, call_acc
        when is_atom(name) and is_integer(arity) ->
          {node, MapSet.put(call_acc, {name, arity})}

        # Function capture with literal_encoder: &foo/N where N is wrapped
        {:&, _, [{:/, _, [{name, _, _}, {:__block__, _, [arity]}]}]} = node, call_acc
        when is_atom(name) and is_integer(arity) ->
          {node, MapSet.put(call_acc, {name, arity})}

        # Bare function call: foo(a, b) => {:foo, meta, [a, b]}
        {name, _meta, args} = node, call_acc when is_atom(name) and is_list(args) ->
          case keyword_or_special?(name) do
            true -> {node, call_acc}
            false -> {node, MapSet.put(call_acc, {name, length(args)})}
          end

        node, call_acc ->
          {node, call_acc}
      end)

    calls
  end

  @keywords ~w[
    def defp defmodule defmacro defmacrop defguard defguardp defstruct
    defexception defprotocol defimpl defdelegate defoverridable
    alias import require use quote unquote __block__ __aliases__
    fn for with case cond if unless try receive raise throw super when and or not
    __MODULE__ __ENV__ __DIR__ __CALLER__ __STACKTRACE__
  ]a

  defp keyword_or_special?(name), do: name in @keywords

  defp build_diagnostic(file, line, name, arity) do
    Diagnostic.warning("6.34",
      title: "Dead private function",
      message: "#{name}/#{arity} is defined but never called within this module",
      why:
        "A private function that is never called is dead code. It adds cognitive " <>
          "load, increases module size, and may mask a missing call (typo or " <>
          "refactoring leftover). If the function is needed, ensure it's called; " <>
          "if not, remove it.",
      alternatives: [
        Fix.new(
          summary: "Remove the dead function",
          detail: "Delete #{name}/#{arity} and any related private helpers it calls.",
          applies_when: "The function is a leftover from a previous refactoring."
        ),
        Fix.new(
          summary: "Call the function where intended",
          detail: "If this function should be called, add the missing call site.",
          applies_when: "A call was accidentally removed or never added."
        )
      ],
      file: file,
      line: line
    )
  end
end
