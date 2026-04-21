defmodule Archdo.Rules.Module.StringConcatInLoop do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.46"

  @impl true
  def description, do: "String concatenation (<>) in loop — O(n²), use IO lists instead"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_concat_in_loops(ast, file)
    end
  end

  defp find_concat_in_loops(ast, file) do
    {_, diagnostics} =
      Macro.prewalk(ast, [], fn
        # Enum.reduce(_, "", fn ..., acc -> acc <> ... end)
        {{:., _, [{:__aliases__, _, [:Enum]}, :reduce]}, meta,
         [_enumerable, init, {:fn, _, _} = fun]} = node,
        acc ->
          case string_init?(init) and fn_body_has_concat?(fun) do
            true -> {node, [build_diagnostic(file, AST.line(meta), :enum_reduce) | acc]}
            false -> {node, acc}
          end

        # for ... reduce: "" do ... acc <> ... end
        {:for, meta, args} = node, acc when is_list(args) ->
          case for_reduce_with_concat?(args) do
            true -> {node, [build_diagnostic(file, AST.line(meta), :for_reduce) | acc]}
            false -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    diagnostics
  end

  defp string_init?(""), do: true
  defp string_init?({:__block__, _, [""]}), do: true
  defp string_init?(_), do: false

  defp fn_body_has_concat?({:fn, _, clauses}) when is_list(clauses) do
    Enum.any?(clauses, fn {:->, _, [_params, body]} -> body_has_concat?(body) end)
  end

  defp fn_body_has_concat?(_), do: false

  defp body_has_concat?(body) do
    AST.contains?(body, fn
      {:<>, _, _} -> true
      _ -> false
    end)
  end

  defp for_reduce_with_concat?(args) do
    reduce_init = find_reduce_init(args)

    case reduce_init do
      {:found, init} ->
        string_init?(init) and for_body_has_concat?(args)

      :not_found ->
        false
    end
  end

  defp find_reduce_init(args) do
    Enum.find_value(args, :not_found, fn
      # [reduce: ""] — keyword list form
      keyword when is_list(keyword) ->
        case Keyword.fetch(keyword, :reduce) do
          {:ok, init} -> {:found, init}
          :error -> nil
        end

      # {:reduce, init} — tuple form
      {:reduce, init} ->
        {:found, init}

      _ ->
        nil
    end)
  end

  defp for_body_has_concat?(args) do
    Enum.any?(args, fn
      [do: {:__block__, _, clauses}] -> Enum.any?(clauses, &body_has_concat?/1)
      [do: body] -> body_has_concat?(body)
      {:do, body} -> body_has_concat?(body)
      _ -> false
    end)
  end

  defp build_diagnostic(file, line, context) do
    detail =
      case context do
        :enum_reduce -> "Enum.reduce with string accumulator and <> concatenation"
        :for_reduce -> "for comprehension with reduce: \"\" and <> concatenation"
      end

    Diagnostic.warning("6.46",
      title: "String concatenation in loop",
      message: "#{detail} — O(n²) copies on every iteration",
      why:
        "Each <> concatenation copies the entire accumulated string. " <>
          "For a list of n items this is O(n²). Build an IO list instead: " <>
          "collect [part | acc] and call IO.iodata_to_binary/1 once at the end.",
      alternatives: [
        Fix.new(
          summary: "Use IO lists instead of string concatenation",
          detail:
            "Replace `Enum.reduce(items, \"\", fn i, acc -> acc <> f(i) end)` " <>
              "with `items |> Enum.map(&f/1) |> IO.iodata_to_binary()`",
          applies_when: "Building a string by accumulating with <> in any loop."
        )
      ],
      file: file,
      line: line
    )
  end
end
