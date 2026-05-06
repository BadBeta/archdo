defmodule Archdo.Rules.Module.MapUpdateOpportunity do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.82"

  @impl true
  def description,
    do:
      "`Map.put(m, k, fun(Map.get(m, k)))` (fetch-modify-put on same key) — " <>
        "use Map.update/4 or Map.update!/3"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    Enum.map(AST.find_all(ast, &fetch_modify_put?/1), fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta))
    end)
  end

  # Match `Map.put(m, k, value_expr)` where `value_expr` contains a
  # `Map.get(m, k, ...)` (or `Map.get(m, k)`) call with the same m / k.
  defp fetch_modify_put?({{:., _, [{:__aliases__, _, [:Map]}, :put]}, _, [m, k, value_expr]}) do
    contains_map_get_with?(value_expr, m, k)
  end

  defp fetch_modify_put?(_), do: false

  defp contains_map_get_with?(ast, target_m, target_k) do
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
    Diagnostic.info("6.82",
      title: "Fetch-modify-put on same key — use Map.update/4 or Map.update!/3",
      message:
        "`Map.put(m, k, fun(Map.get(m, k)))` re-fetches the key after the put-target is " <>
          "already known. `Map.update/4` (with default) or `Map.update!/3` (raise on " <>
          "missing) does it in one call.",
      why:
        "Two map operations (get + put) for one logical update. `Map.update` was added so " <>
          "the closure receives the current value and the put happens internally — single " <>
          "hash lookup, single mutation, no risk of typo divergence between the get-key " <>
          "and the put-key.",
      alternatives: [
        Fix.new(
          summary: "Replace with Map.update/4 (provides default for missing key)",
          detail: "Map.update(map, :counter, 1, &(&1 + 1))",
          applies_when: "When the key may be absent — supply a default."
        ),
        Fix.new(
          summary: "Replace with Map.update!/3 (raises if the key is absent)",
          detail: "Map.update!(map, :counter, &(&1 + 1))",
          applies_when:
            "When the key MUST exist — raising is the right behaviour for missing key."
        )
      ],
      references: ["elixir-implementing/SKILL.md#2.6"],
      context: %{},
      file: file,
      line: line
    )
  end
end
