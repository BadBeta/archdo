defmodule Archdo.Rules.Module.RepeatedGuardChain do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.73"

  @impl true
  def description,
    do: "Same `when` guard chain repeated across 2+ function heads — extract a `defguard`"

  @def_kws [:def, :defp, :defmacro, :defmacrop]

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    {_, defs} =
      Macro.prewalk(ast, [], fn
        {def_kw, meta, [head, _kw_or_body]} = node, acc when def_kw in @def_kws ->
          case extract_guard(head) do
            nil -> {node, acc}
            guard -> {node, [{strip_meta(guard), AST.line(meta)} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    # Skip trivial single-call guards (`when is_atom(x)`); only
    # interesting when 2+ predicates are conjoined (worth a defguard).
    defs
    |> Enum.filter(fn {guard, _line} -> compound_guard?(guard) end)
    |> Enum.group_by(fn {guard, _} -> guard end)
    |> Enum.flat_map(fn
      {_guard, [_]} ->
        []

      {_guard, [_, _ | _] = entries} ->
        # Flag the FIRST occurrence; the message says how many heads
        # share the chain. Avoids spamming N findings for one chain.
        entries |> Enum.map(fn {_, line} -> line end) |> Enum.min() |> List.wrap()
    end)
    |> Enum.map(fn line -> build_diagnostic(file, line) end)
  end

  defp extract_guard({:when, _, [_inner, guard]}), do: guard
  defp extract_guard(_), do: nil

  # A guard is compound when it has at least one `and`/`or` operator
  # at the top level — i.e., chains 2+ predicates. A single
  # `is_integer(x)` is not interesting.
  defp compound_guard?({:and, _, _}), do: true
  defp compound_guard?({:or, _, _}), do: true
  defp compound_guard?(_), do: false

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.73",
      title: "Repeated guard chain — extract a `defguard`",
      message:
        "Two or more function heads in this module use the same `when ... and ... and ...` " <>
          "guard chain. Extract it as a `defguard` for a single name and one place to change.",
      why:
        "`defguard` (and `defguardp` for private) was added so guard chains can be named " <>
          "and reused. Repeating `when is_integer(x) and x > 0 and x < 100` across many " <>
          "function heads couples them: changing the range means editing every head, and a " <>
          "skipped head silently drifts. A named guard centralizes the rule.",
      alternatives: [
        Fix.new(
          summary: "Extract a `defguard` (or `defguardp`)",
          detail:
            "defguard valid_range(x) when is_integer(x) and x > 0 and x < 100\n\n" <>
              "def positive?(x) when valid_range(x), do: true\n" <>
              "def normalize(x) when valid_range(x), do: x",
          applies_when: "When 2+ function heads share the same compound guard."
        )
      ],
      references: ["elixir-implementing/SKILL.md#5.6", "elixir-implementing/SKILL.md#2.3"],
      context: %{},
      file: file,
      line: line
    )
  end
end
