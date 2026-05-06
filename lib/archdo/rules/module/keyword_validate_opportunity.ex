defmodule Archdo.Rules.Module.KeywordValidateOpportunity do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.83"

  @impl true
  def description,
    do:
      "3+ `Keyword.get(opts, :k, default)` calls on the same opts var — " <>
        "use Keyword.validate!/2"

  @threshold 3
  @def_kws [:def, :defp, :defmacro, :defmacrop]

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    {_, hits} =
      Macro.prewalk(ast, [], fn
        {def_kw, _meta, [_head, kw_or_body]} = node, acc when def_kw in @def_kws ->
          {node, maybe_collect(kw_or_body, acc)}

        node, acc ->
          {node, acc}
      end)

    Enum.map(hits, fn {line, count, var} ->
      build_diagnostic(file, line, count, var)
    end)
  end

  defp maybe_collect(kw_or_body, acc) do
    body = extract_body(kw_or_body)

    case count_keyword_gets_per_var(body) do
      {} -> acc
      {var, count, line} when count >= @threshold -> [{line, count, var} | acc]
      _ -> acc
    end
  end

  defp extract_body(kw) when is_list(kw) do
    Enum.find_value(kw, fn
      {{:__block__, _, [:do]}, body} -> body
      {:do, body} -> body
      _ -> nil
    end)
  end

  defp extract_body(body), do: body

  # Walk body for `Keyword.get(var, ...)` calls. Group by `var` and
  # find the variable with the most calls.
  defp count_keyword_gets_per_var(nil), do: {}

  defp count_keyword_gets_per_var(body) do
    {_, calls} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, [:Keyword]}, :get]}, meta, [{var, _, ctx} | _]} = node, acc
        when is_atom(var) and is_atom(ctx) ->
          {node, [{var, AST.line(meta)} | acc]}

        node, acc ->
          {node, acc}
      end)

    by_var = Enum.group_by(calls, fn {var, _line} -> var end)

    case by_var do
      m when map_size(m) == 0 ->
        {}

      _ ->
        {var, occurrences} = Enum.max_by(by_var, fn {_, list} -> length(list) end)
        first_line = occurrences |> Enum.map(fn {_, line} -> line end) |> Enum.min()
        {var, length(occurrences), first_line}
    end
  end

  defp build_diagnostic(file, line, count, var) do
    Diagnostic.info("6.83",
      title: "#{count} Keyword.get calls on `#{var}` — use Keyword.validate!/2",
      message:
        "Function reads #{count} keyword keys from `#{var}` via separate Keyword.get calls. " <>
          "`Keyword.validate!/2` validates and provides defaults at the function entry — " <>
          "one call, all defaults documented at the same site, unknown keys raise.",
      why:
        "`Keyword.validate!/2` (Elixir 1.13+) is the canonical way to handle a function's " <>
          "options. It does three things in one call: documents the accepted keys (the " <>
          "function's API surface), provides defaults, and rejects unknown keys at the " <>
          "boundary so typos fail fast instead of silently using a default. Spreading " <>
          "Keyword.get calls across the function body fragments this contract.",
      alternatives: [
        Fix.new(
          summary: "Use Keyword.validate!/2 at function entry",
          detail:
            "def start_link(opts) do\n" <>
              "  opts = Keyword.validate!(opts, timeout: 5_000, max_retries: 3, name: __MODULE__)\n" <>
              "  GenServer.start_link(__MODULE__, opts, name: opts[:name])\n" <>
              "end",
          applies_when: "When the function takes a keyword-options argument."
        )
      ],
      references: ["elixir-implementing/SKILL.md#2.6", "elixir-implementing/SKILL.md#6"],
      context: %{count: count, var: var},
      file: file,
      line: line
    )
  end
end
