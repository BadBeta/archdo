defmodule Archdo.Rules.Module.MapHasKeyThenGet do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.72"

  @impl true
  def description,
    do: "`if Map.has_key?(m, k) do Map.get(m, k) ... end` — use `Map.fetch/2`"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    Enum.map(AST.find_all(ast, &has_key_then_get?/1), fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta))
    end)
  end

  # `if Map.has_key?(m, k) do <body using Map.get(m, k)> ... end`
  defp has_key_then_get?({:if, _, [cond_expr, kw]}) when is_list(kw) do
    case has_key_args(cond_expr) do
      {:ok, m, k} -> get_with_same_args?(kw, m, k)
      :error -> false
    end
  end

  defp has_key_then_get?(_), do: false

  defp has_key_args({{:., _, [{:__aliases__, _, [:Map]}, :has_key?]}, _, [m, k]}),
    do: {:ok, m, k}

  defp has_key_args(_), do: :error

  defp get_with_same_args?(kw, target_m, target_k) do
    do_body = extract_kw(kw, :do)
    contains_map_get?(do_body, target_m, target_k)
  end

  defp extract_kw(kw, key) do
    Enum.find_value(kw, fn
      {^key, val} -> val
      {{:__block__, _, [^key]}, val} -> val
      _ -> nil
    end)
  end

  defp contains_map_get?(nil, _, _), do: false

  defp contains_map_get?(ast, target_m, target_k) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, [:Map]}, get_fun]}, _, [m, k | _]} = node, _acc
        when get_fun in [:get, :fetch!] ->
          {node, same_arg?(m, target_m) and same_arg?(k, target_k)}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp same_arg?(a, b), do: strip(a) == strip(b)

  defp strip(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.72",
      title: "`Map.has_key?` then `Map.get` — use `Map.fetch/2`",
      message:
        "Pattern `if Map.has_key?(m, k), do: Map.get(m, k)` does two map lookups for one " <>
          "logical operation. `Map.fetch/2` returns `{:ok, value}` or `:error` in a single " <>
          "lookup.",
      why:
        "`Map.fetch/2` is the canonical 'get-or-fail' form for maps. It returns `{:ok, " <>
          "value}` if the key exists or `:error` if it doesn't — exactly the data the " <>
          "has_key?+get pattern is reconstructing manually. Single hash-lookup, single " <>
          "well-known shape, composes cleanly with `with` chains.",
      alternatives: [
        Fix.new(
          summary: "Replace with Map.fetch/2",
          detail:
            "case Map.fetch(map, key) do\n" <>
              "  {:ok, value} -> {:ok, value}\n" <>
              "  :error -> :error\n" <>
              "end\n# Or just: Map.fetch(map, key)",
          applies_when: "When the get is used to extract the value, not the presence."
        )
      ],
      references: ["elixir-implementing/SKILL.md#2.3"],
      context: %{},
      file: file,
      line: line
    )
  end
end
