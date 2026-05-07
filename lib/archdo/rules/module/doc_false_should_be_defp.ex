defmodule Archdo.Rules.Module.DocFalseShouldBeDefp do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.AST.Unwrap

  @impl true
  def id, do: "6.87"

  @impl true
  def description,
    do: "`@doc false` on a `def` — the function is still callable. Use `defp` for true privacy."

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    {_, all_block_stmts} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [_alias, kw]} = node, acc when is_list(kw) ->
          case Unwrap.kw_get(kw, :do) do
            {:ok, body} -> {node, [block_stmts(body) | acc]}
            :error -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.flat_map(all_block_stmts, &scan_block(&1, file))
  end

  defp block_stmts({:__block__, _, stmts}) when is_list(stmts), do: stmts
  defp block_stmts(single), do: [single]

  # Walk the module body's statements; flag any `def` whose preceding
  # statements (since the previous `def`/`defp`) include `@doc false`.
  # Fold across stmts tracking the most recent doc marker.
  defp scan_block(stmts, file) do
    {hits, _state} =
      Enum.reduce(stmts, {[], :no_doc}, fn stmt, {acc, doc_state} ->
        case classify_stmt(stmt) do
          :doc_false ->
            {acc, :doc_false}

          {:def, line, name} when doc_state == :doc_false ->
            case cross_module_internal_convention?(name) do
              true -> {acc, :no_doc}
              false -> {[line | acc], :no_doc}
            end

          {:def, _, _} ->
            {acc, :no_doc}

          {:defp, _, _} ->
            {acc, :no_doc}

          :other ->
            {acc, doc_state}
        end
      end)

    Enum.map(hits, fn line -> build_diagnostic(file, line) end)
  end

  defp classify_stmt({:@, _, [{:doc, _, [false]}]}), do: :doc_false

  defp classify_stmt({:@, _, [{:doc, _, [{:__block__, _, [false]}]}]}), do: :doc_false

  defp classify_stmt({:def, meta, [head | _]}), do: {:def, AST.line(meta), def_name(head)}
  defp classify_stmt({:def, meta, _}), do: {:def, AST.line(meta), nil}

  defp classify_stmt({:defp, meta, [head | _]}),
    do: {:defp, AST.line(meta), def_name(head)}

  defp classify_stmt({:defp, meta, _}), do: {:defp, AST.line(meta), nil}
  defp classify_stmt(_), do: :other

  # Extract the function name atom from a def/defp head.
  # Handles `def name(args)`, `def name(args) when guard`, and the
  # zero-arg `def name`.
  defp def_name({:when, _, [{name, _, _} | _]}) when is_atom(name), do: name
  defp def_name({name, _, _}) when is_atom(name), do: name
  defp def_name(_), do: nil

  # `__name__/arity` (double-underscore prefix AND suffix on the name) is
  # the established "public-but-internal" Elixir convention: public so
  # cross-module callers in the same project can use it, `@doc false` to
  # hide from docs. Examples: Phoenix.__init__/2, Plug.Conn.__protocol__/1,
  # Module.__info__/1. The rule's "use defp instead" advice is wrong here
  # — defp would break the cross-module callers that the convention is
  # designed to permit.
  defp cross_module_internal_convention?(name) when is_atom(name) do
    str = Atom.to_string(name)
    String.starts_with?(str, "__") and String.ends_with?(str, "__")
  end

  defp cross_module_internal_convention?(_), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.87",
      title: "`@doc false` on a `def` — should be `defp`",
      message:
        "This function is marked `@doc false` (intent: hide from docs) but defined as " <>
          "`def`, so it's still part of the public API and external callers can invoke it. " <>
          "If the function is truly internal, use `defp`.",
      why:
        "`@doc false` only affects documentation generation; it does NOT change the " <>
          "function's visibility. Other modules can still call it; tools like `mix xref` " <>
          "see it as part of the public surface. `defp` is the actual private-function " <>
          "mechanism — the function isn't exported and can't be called from outside.",
      alternatives: [
        Fix.new(
          summary: "Use `defp` for actual privacy",
          detail:
            "defp internal_helper(x), do: x + 1\n" <>
              "# vs\n" <>
              "@doc false\n" <>
              "def internal_helper(x), do: x + 1",
          applies_when: "When the function is genuinely internal."
        ),
        Fix.new(
          summary: "Or keep `@doc false` if the function MUST stay public (e.g., used by macros)",
          detail:
            "Document why explicitly: `@doc \"Public for macro expansion; not part of API.\"`\n" <>
              "Mark internal use cases. The `@doc false` form is acceptable when:\n" <>
              "- A macro expands to a call to this function in user code.\n" <>
              "- A protocol implementation calls it (must be public).\n" <>
              "- An umbrella sibling needs to call it.",
          applies_when:
            "When the function is genuinely public (in the export sense) but undocumented."
        )
      ],
      references: ["elixir-implementing/SKILL.md#2.8"],
      context: %{},
      file: file,
      line: line
    )
  end
end
