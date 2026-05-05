defmodule Archdo.Rules.Module.TapOpportunity do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.AST.Unwrap

  @impl true
  def id, do: "6.64"

  @impl true
  def description,
    do: "Variable bound, used for a side effect, then returned — should be `tap/2`"

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
        {def_kw, _meta, [_head, kw]} = node, acc when def_kw in @def_kws and is_list(kw) ->
          case Unwrap.kw_get(kw, :do) do
            {:ok, body} -> {node, maybe_collect_hit(body, acc)}
            :error -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.map(hits, fn line -> build_diagnostic(file, line) end)
  end

  defp maybe_collect_hit(body, acc) do
    case extract_block_stmts(body) do
      [{:=, _, [{name, _, ctx}, _rhs]} = assign, mid, {ret_name, _, ret_ctx}]
      when is_atom(name) and is_atom(ctx) and is_atom(ret_name) and is_atom(ret_ctx) ->
        case ret_name == name and mentions_var?(mid, name) do
          true -> [assign_line(assign) | acc]
          false -> acc
        end

      _ ->
        acc
    end
  end

  defp extract_block_stmts({:__block__, _, stmts}) when is_list(stmts), do: stmts
  defp extract_block_stmts(_), do: []

  defp assign_line({:=, meta, _}), do: AST.line(meta)

  defp mentions_var?(ast, target_name) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {name, _, ctx} = node, _acc when name == target_name and is_atom(ctx) -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.64",
      title: "Variable bound, used for side effect, then returned — `tap/2`",
      message:
        "This function binds a variable, calls a function with it (side effect), then " <>
          "returns the same variable unchanged. The idiomatic form is `value |> tap(&side_effect/1)`.",
      why:
        "`Kernel.tap/2` was added for exactly this shape: 'do something with this value, " <>
          "then continue with the value unchanged'. The bind-then-side-effect-then-return " <>
          "form predates `tap/2`. Using `tap/2` makes the side-effect role explicit (the " <>
          "value flows through unchanged).",
      alternatives: [
        Fix.new(
          summary: "Replace with `tap/2`",
          detail:
            "compute(items) |> tap(&IO.inspect(&1, label: \"total\"))\n" <>
              "Or in a longer pipeline:\n" <>
              "items\n|> compute()\n|> tap(&log/1)",
          applies_when: "When the side-effect call doesn't transform the value."
        )
      ],
      references: ["elixir-implementing/SKILL.md#5.1"],
      context: %{},
      file: file,
      line: line
    )
  end
end
