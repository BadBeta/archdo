defmodule Archdo.Rules.Module.EmptyMapPatternMatchesAny do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.71"

  @impl true
  def description,
    do: "`def f(%{})` matches ANY map, not just an empty one — use a `map_size/1` guard"

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
        {def_kw, meta, [head, _kw_or_body]} = node, acc when def_kw in @def_kws ->
          case head_has_empty_map_pattern?(head) do
            true -> {node, [AST.line(meta) | acc]}
            false -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.map(hits, fn line -> build_diagnostic(file, line) end)
  end

  # Head is `{name, _, args}` or `{:when, _, [{name, _, args}, _guard]}`.
  defp head_has_empty_map_pattern?({:when, _, [inner, _guard]}),
    do: head_has_empty_map_pattern?(inner)

  defp head_has_empty_map_pattern?({name, _, args}) when is_atom(name) and is_list(args),
    do: Enum.any?(args, &empty_map_pattern?/1)

  defp head_has_empty_map_pattern?(_), do: false

  defp empty_map_pattern?({:%{}, _, []}), do: true
  defp empty_map_pattern?(_), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.warning("6.71",
      title: "`%{}` pattern matches ANY map",
      message:
        "This function head uses `%{}` as a pattern — but `%{}` matches ANY map, not just " <>
          "empty ones. The clause fires on every map input, which is rarely the author's " <>
          "intent.",
      why:
        "In Elixir, the `%{}` literal is the open-map pattern: it matches any map regardless " <>
          "of size. A common bug is treating it as a literal-empty-map check. To dispatch " <>
          "on 'empty map vs non-empty map', use a `when map_size(m) == 0` guard.",
      alternatives: [
        Fix.new(
          summary: "Use `when map_size(m) == 0` for empty-map dispatch",
          detail:
            "def empty?(m) when map_size(m) == 0, do: true\n" <>
              "def empty?(_), do: false",
          applies_when: "When you need to distinguish empty maps from non-empty ones."
        ),
        Fix.new(
          summary: "Or pattern-match on specific keys when that's the actual intent",
          detail:
            "def name(%{name: name}), do: name\n" <>
              "def name(%{}), do: :no_name  # any other map — explicit catchall",
          applies_when:
            "When `%{}` was meant as a permissive 'any-map-without-this-key' catchall."
        )
      ],
      references: ["elixir-implementing/SKILL.md#5.2", "elixir-implementing/SKILL.md#7.6"],
      context: %{},
      file: file,
      line: line
    )
  end
end
