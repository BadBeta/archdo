defmodule Archdo.Rules.Module.BodyGuardOpportunity do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.AST.Unwrap

  @impl true
  def id, do: "6.77"

  @impl true
  def description,
    do: "Body `unless is_*(x), do: raise` — express the type constraint as a head guard"

  @def_kws [:def, :defp, :defmacro, :defmacrop]

  # Type-predicate guards that are unambiguous head-guard fits.
  # Range / value comparisons are intentionally NOT here — those may
  # legitimately depend on runtime thresholds in the body.
  @type_predicates [
    :is_atom,
    :is_binary,
    :is_bitstring,
    :is_boolean,
    :is_float,
    :is_function,
    :is_integer,
    :is_list,
    :is_map,
    :is_number,
    :is_pid,
    :is_port,
    :is_reference,
    :is_tuple,
    :is_struct
  ]

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
        {def_kw, meta, [head, kw_or_body]} = node, acc when def_kw in @def_kws ->
          case has_body_typecheck_with_raise?(head, kw_or_body) do
            true -> {node, [AST.line(meta) | acc]}
            false -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.map(hits, fn line -> build_diagnostic(file, line) end)
  end

  defp has_body_typecheck_with_raise?(head, kw_or_body) do
    not has_head_guard?(head) and body_has_typecheck_raise?(extract_body(kw_or_body))
  end

  defp has_head_guard?({:when, _, _}), do: true
  defp has_head_guard?(_), do: false

  defp extract_body(kw) when is_list(kw) do
    case Unwrap.kw_get(kw, :do) do
      {:ok, body} -> body
      :error -> nil
    end
  end

  defp extract_body(body), do: body

  defp body_has_typecheck_raise?(nil), do: false

  defp body_has_typecheck_raise?(body) do
    {_, found?} =
      Macro.prewalk(body, false, fn
        # `unless is_X(var), do: raise(...)`
        {:unless, _, [predicate, kw]} = node, _acc when is_list(kw) ->
          {node, type_predicate?(predicate) and contains_raise?(kw)}

        # `if not is_X(var), do: raise(...)`
        {:if, _, [{:not, _, [predicate]}, kw]} = node, _acc when is_list(kw) ->
          {node, type_predicate?(predicate) and contains_raise?(kw)}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp type_predicate?({fun, _, args})
       when fun in @type_predicates and is_list(args) and args != [],
       do: true

  defp type_predicate?(_), do: false

  defp contains_raise?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {:raise, _, _} = node, _acc -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.77",
      title: "Body type-check with raise — express as a head guard",
      message:
        "This function uses `unless is_X(arg), do: raise` (or `if not is_X(arg), do: raise`) " <>
          "in the body. The same constraint is clearer as a `when is_X(arg)` guard on the " <>
          "function head.",
      why:
        "Head guards are part of the function's pattern-match contract: dispatching mismatches " <>
          "to the next clause (or producing a FunctionClauseError) is more uniform than " <>
          "raising ArgumentError from the body. Head guards also enable multi-clause " <>
          "dispatch — type-correct callers go to one clause, type-incorrect callers to a " <>
          "fallback or error clause.",
      alternatives: [
        Fix.new(
          summary: "Move the type predicate to a head guard",
          detail:
            "def double(x) when is_integer(x), do: x * 2\n" <>
              "def double(x), do: raise ArgumentError, \"expected integer, got: \#{inspect(x)}\"",
          applies_when:
            "When the body's type-check is the only validation (no value-range check)."
        )
      ],
      references: ["elixir-implementing/SKILL.md#5.6", "elixir-implementing/SKILL.md#2.3"],
      context: %{},
      file: file,
      line: line
    )
  end
end
