defmodule Archdo.Rules.Module.MapPutChainAsMerge do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.81"

  @impl true
  def description,
    do: "Chain of `Map.put` calls in a pipeline — use `Map.merge/2` for the batch"

  @threshold 3

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    {_, hits} = Macro.prewalk(ast, [], &collect_chain/2)
    Enum.map(hits, fn {line, count} -> build_diagnostic(file, line, count) end)
  end

  # Walk for the OUTERMOST pipe in any Map.put chain. When we find one
  # of length >= threshold, record it AND replace the subtree with a
  # placeholder so prewalk doesn't re-visit the inner pipes (which
  # would produce duplicate findings).
  defp collect_chain({:|>, meta, [lhs, rhs]} = node, acc) do
    case map_put_call?(rhs) do
      true ->
        count = 1 + count_consecutive_map_puts(lhs)

        case count >= @threshold do
          true ->
            {{:__archdo_visited__, [], []}, [{AST.line(meta), count} | acc]}

          false ->
            {node, acc}
        end

      false ->
        {node, acc}
    end
  end

  defp collect_chain(node, acc), do: {node, acc}

  defp map_put_call?({{:., _, [{:__aliases__, _, [:Map]}, :put]}, _, args})
       when is_list(args),
       do: true

  defp map_put_call?(_), do: false

  # Count consecutive Map.put calls walking down the pipe chain.
  # Stops at the first non-pipe LHS or non-Map.put RHS.
  defp count_consecutive_map_puts({:|>, _, [lhs, rhs]}) do
    case map_put_call?(rhs) do
      true -> 1 + count_consecutive_map_puts(lhs)
      false -> 0
    end
  end

  defp count_consecutive_map_puts(_), do: 0

  defp build_diagnostic(file, line, count) do
    Diagnostic.info("6.81",
      title: "#{count} chained Map.put calls — use Map.merge/2",
      message:
        "Pipeline contains #{count} consecutive `Map.put` calls on the same map. " <>
          "`Map.merge/2` does the same in one step with a clear key/value picture.",
      why:
        "Each `Map.put/3` call is a separate map mutation; chaining N of them traverses " <>
          "the map's hash structure N times. `Map.merge/2` does it in one pass and groups " <>
          "the keys at one read-site, making the merge intent visible without scanning the " <>
          "pipeline.",
      alternatives: [
        Fix.new(
          summary: "Replace with Map.merge/2",
          detail:
            "Map.merge(base, %{\n  active: true,\n  created_at: DateTime.utc_now(),\n  source: :web\n})",
          applies_when:
            "When the puts are independent (no put depends on a previous put's value)."
        ),
        Fix.new(
          summary: "Or use the struct-update syntax for a struct",
          detail: "%{base | active: true, created_at: DateTime.utc_now(), source: :web}",
          applies_when:
            "When `base` is a struct or has all the keys; struct update raises on unknown keys."
        )
      ],
      references: ["elixir-implementing/SKILL.md#2.6", "elixir-implementing/SKILL.md#7.5"],
      context: %{count: count},
      file: file,
      line: line
    )
  end
end
