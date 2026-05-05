defmodule Archdo.Rules.Module.CallbackHell do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.59"

  @impl true
  def description,
    do: "Callback hell — function body has more than @threshold nested anonymous functions"

  @threshold 3

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_callback_hell(file, ast)
    end
  end

  defp find_callback_hell(file, ast) do
    Enum.map(AST.find_all(ast, &deep_nested_anon?/1), fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta))
    end)
  end

  # Fires when an anonymous-fn / capture node has more than @threshold
  # ancestors that are also anonymous-fns / captures. The walk is a
  # forward depth-counter — when we detect a node at depth > threshold,
  # it's the nested one. We mark the depth-1 outermost node as the
  # finding location so the message points at the start of the chain.
  defp deep_nested_anon?({:fn, _, _} = node) do
    nesting_depth(node, 0) > @threshold
  end

  defp deep_nested_anon?({:&, _, _} = node) do
    nesting_depth(node, 0) > @threshold
  end

  defp deep_nested_anon?(_), do: false

  defp nesting_depth({:fn, _, [{:->, _, [_args, body]}]}, depth) do
    nesting_depth(body, depth + 1)
  end

  defp nesting_depth({:fn, _, [{:->, _, [_args, body]} | _other_clauses]}, depth) do
    # Multi-clause fn — count first clause body for depth
    nesting_depth(body, depth + 1)
  end

  defp nesting_depth({:&, _, [body]}, depth) do
    nesting_depth(body, depth + 1)
  end

  defp nesting_depth({_, _, args}, depth) when is_list(args) do
    args
    |> Enum.map(&nesting_depth(&1, depth))
    |> max_or(depth)
  end

  defp nesting_depth(list, depth) when is_list(list) do
    list
    |> Enum.map(&nesting_depth(&1, depth))
    |> max_or(depth)
  end

  defp nesting_depth({a, b}, depth) do
    max(nesting_depth(a, depth), nesting_depth(b, depth))
  end

  defp nesting_depth(_, depth), do: depth

  defp max_or([], default), do: default
  defp max_or(list, _default), do: Enum.max(list)

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.59",
      title: "Callback hell — deeply nested anonymous functions",
      message:
        "More than #{@threshold} levels of nested anonymous functions / captures — the " <>
          "control flow is hard to follow and the binding scope at each level is " <>
          "non-obvious.",
      why:
        "Nested anonymous functions hide the data flow inside a stack of closures. Each " <>
          "level captures bindings from its parent, so reading the innermost body requires " <>
          "tracking N parent scopes. Real-world code at this depth tends to also have bugs " <>
          "around variable shadowing and unintended captures.",
      alternatives: [
        Fix.new(
          summary: "Extract a private helper function for the inner work",
          detail:
            "`Enum.map(items, &process_item/1)` with a real `defp process_item(item) do ... " <>
              "end` is far more readable than a deep `fn` chain. Each helper has a name " <>
              "that documents the intent of its level.",
          applies_when: "Always when the inner body is non-trivial."
        ),
        Fix.new(
          summary: "Flatten via `with` or named intermediates",
          detail:
            "If the nesting reflects an ok/error chain, a `with` block at the outer scope " <>
              "may replace a 3+-level callback stack with a flat sequence.",
          applies_when: "When the nesting is driven by error-handling, not data shape."
        )
      ],
      references: ["GUIDE.md#6.59"],
      context: %{},
      file: file,
      line: line
    )
  end
end
