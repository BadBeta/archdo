defmodule Archdo.Rules.Module.NestedControlFlow do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @nesting_threshold 3

  @impl true
  def id, do: "6.44"

  @impl true
  def description, do: "Deeply nested control flow — with inside with, or 3+ levels of case/cond/if/with"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_deep_nesting(file, ast)
    end
  end

  defp find_deep_nesting(file, ast) do
    fns = AST.extract_functions(ast, :all)

    Enum.flat_map(fns, fn {name, arity, _meta, _args, body} ->
      diagnostics = walk_for_nesting(body, 0, [])

      Enum.map(diagnostics, fn {line, kind} ->
        build_diagnostic(file, line, name, arity, kind)
      end)
    end)
  end

  # Walk the AST tracking nesting depth of control flow constructs.
  # Returns a list of {line, kind} tuples for violations.
  defp walk_for_nesting(nil, _depth, acc), do: acc

  defp walk_for_nesting({:with, meta, args}, depth, acc) when is_list(args) do
    # with inside with is always flagged (depth >= 1 means we're inside a with)
    acc =
      case depth > 0 and parent_is_control_flow?(depth) do
        true -> [{AST.line(meta), :with_inside_control_flow} | acc]
        false -> acc
      end

    new_depth = depth + 1

    acc =
      case new_depth >= @nesting_threshold do
        true -> [{AST.line(meta), :deep_nesting} | acc]
        false -> acc
      end

    walk_children(args, new_depth, acc)
  end

  defp walk_for_nesting({form, meta, args}, depth, acc)
       when form in [:case, :cond, :if] and is_list(args) do
    new_depth = depth + 1

    acc =
      case new_depth >= @nesting_threshold do
        true -> [{AST.line(meta), :deep_nesting} | acc]
        false -> acc
      end

    walk_children(args, new_depth, acc)
  end

  defp walk_for_nesting({_form, _meta, args}, depth, acc) when is_list(args) do
    walk_children(args, depth, acc)
  end

  defp walk_for_nesting({left, right}, depth, acc) do
    acc = walk_for_nesting(left, depth, acc)
    walk_for_nesting(right, depth, acc)
  end

  defp walk_for_nesting(list, depth, acc) when is_list(list) do
    Enum.reduce(list, acc, fn node, acc -> walk_for_nesting(node, depth, acc) end)
  end

  defp walk_for_nesting(_literal, _depth, acc), do: acc

  defp walk_children(args, depth, acc) do
    Enum.reduce(args, acc, fn child, acc ->
      walk_for_nesting(child, depth, acc)
    end)
  end

  defp parent_is_control_flow?(_depth), do: true

  defp build_diagnostic(file, line, name, arity, :with_inside_control_flow) do
    Diagnostic.info("6.44",
      title: "Nested control flow: with inside control flow in #{name}/#{arity}",
      message: "`with` nested inside another control flow construct — flatten or extract a function",
      why:
        "Nested `with` chains are hard to follow. Each `with` should represent " <>
          "a single sequence of dependent operations. If you need `with` inside `with`, " <>
          "extract the inner chain into a named function.",
      alternatives: [
        Fix.new(
          summary: "Extract the inner with into a named function",
          detail:
            "Move the nested `with` block into a `defp` function with a descriptive name. " <>
              "The outer `with` calls this function as one of its steps.",
          applies_when: "Always — nested with chains should be flattened."
        )
      ],
      file: file,
      line: line
    )
  end

  defp build_diagnostic(file, line, name, arity, :deep_nesting) do
    Diagnostic.info("6.44",
      title: "Deeply nested control flow in #{name}/#{arity}",
      message: "3+ levels of nested case/with/cond/if — extract inner logic into helper functions",
      why:
        "Deeply nested control flow is hard to read and reason about. " <>
          "Each nesting level multiplies the number of code paths a reader must track. " <>
          "Extract nested blocks into well-named private functions.",
      alternatives: [
        Fix.new(
          summary: "Extract inner branches into named functions",
          detail:
            "Replace the innermost case/with/cond with a call to a descriptive private function.",
          applies_when: "Nesting reaches 3+ levels of control flow constructs."
        ),
        Fix.new(
          summary: "Use with to flatten nested cases",
          detail:
            "If the nesting is a chain of case-on-result patterns, a single `with` chain " <>
              "may replace multiple levels.",
          applies_when: "Nested cases match on {:ok, _}/{:error, _} tuples."
        )
      ],
      file: file,
      line: line
    )
  end
end
