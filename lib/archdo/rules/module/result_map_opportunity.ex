defmodule Archdo.Rules.Module.ResultMapOpportunity do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.AST.Unwrap

  @impl true
  def id, do: "6.96"

  @impl true
  def description,
    do: "Verbose `case` over an `{:ok, _} | {:error, _}` result — Result.map territory"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_result_map_opportunities(file, ast)
    end
  end

  defp find_result_map_opportunities(file, ast) do
    ast
    |> AST.find_all(&case_with_do?/1)
    |> Enum.flat_map(&maybe_flag(&1, file))
  end

  # `case x do ... end` and `expr |> case do ... end` — only the kw-list arg shape
  defp case_with_do?({:case, _, [_subject, kw]}) when is_list(kw), do: kw_has_do?(kw)
  defp case_with_do?({:case, _, [kw]}) when is_list(kw), do: kw_has_do?(kw)
  defp case_with_do?(_), do: false

  defp kw_has_do?(kw) do
    case Unwrap.kw_get(kw, :do) do
      {:ok, clauses} when is_list(clauses) -> true
      _ -> false
    end
  end

  defp maybe_flag({:case, meta, [_subject, kw]}, file), do: flag_if_match(meta, kw, file)
  defp maybe_flag({:case, meta, [kw]}, file), do: flag_if_match(meta, kw, file)
  defp maybe_flag(_, _), do: []

  defp flag_if_match(meta, kw, file) do
    {:ok, clauses} = Unwrap.kw_get(kw, :do)

    case classify_clauses(clauses) do
      true -> [build_diagnostic(file, AST.line(meta))]
      false -> []
    end
  end

  # Two-clause case where:
  #   clause 1: {:ok, var} -> {:ok, expr}  (var/expr unconstrained)
  #   clause 2: {:error, _}=e -> e   OR   {:error, r} -> {:error, r}
  defp classify_clauses([
         {:->, _, [[ok_pat], ok_body]},
         {:->, _, [[err_pat], err_body]}
       ]) do
    ok_clause?(ok_pat, ok_body) and err_passthrough?(err_pat, err_body)
  end

  defp classify_clauses(_), do: false

  defp ok_clause?(pat, body) do
    case {unwrap_tagged_2tuple(pat), unwrap_tagged_2tuple(body)} do
      {{:ok, _, _}, {:ok, _, _}} -> true
      _ -> false
    end
  end

  # Either `{:error, _} = name` then body returns `name`,
  # or `{:error, var}` then body returns `{:error, var}`.
  defp err_passthrough?({:=, _, [tuple, {bind_name, _, ctx}]}, {bind_name, _, ctx2})
       when is_atom(bind_name) and is_atom(ctx) and is_atom(ctx2) do
    error_tagged?(tuple)
  end

  defp err_passthrough?(pat, body) do
    case {unwrap_tagged_2tuple(pat), unwrap_tagged_2tuple(body)} do
      {{:error, {var, _, ctx}, _meta}, {:error, {var, _, ctx2}, _meta2}}
      when is_atom(var) and var != :_ and is_atom(ctx) and is_atom(ctx2) ->
        true

      _ ->
        false
    end
  end

  # Returns `{tag_atom, second_element, meta}` for both raw and
  # literal-encoder-wrapped 2-tuple AST shapes; `:no_match` otherwise.
  defp unwrap_tagged_2tuple({:__block__, _, [{tag, second}]}) do
    case Unwrap.literal(tag) do
      a when is_atom(a) -> {a, second, []}
      _ -> :no_match
    end
  end

  defp unwrap_tagged_2tuple({tag, second}) do
    case Unwrap.literal(tag) do
      a when is_atom(a) -> {a, second, []}
      _ -> :no_match
    end
  end

  defp unwrap_tagged_2tuple(_), do: :no_match

  defp error_tagged?(node) do
    case unwrap_tagged_2tuple(node) do
      {:error, _, _} -> true
      _ -> false
    end
  end

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.96",
      title: "Verbose ok/error `case` is Result.map",
      message:
        "This `case` matches `{:ok, v}` to wrap a transform and " <>
          "passes the error through unchanged — that's the shape of `Result.map`.",
      why:
        "Wrapping a value in `{:ok, _}` and forwarding `{:error, _}` is the " <>
          "canonical Result.map. The intent — apply a function to the success " <>
          "value, do nothing on error — is buried under the `case` ceremony. " <>
          "A `with` chain, an explicit `Result.map/2` from a result-handling " <>
          "library, or a small helper makes the intent explicit and removes " <>
          "the visual noise.",
      alternatives: [
        Fix.new(
          summary: "Use `with` for a single transform",
          detail:
            "A single-arrow `with` reads cleanly when the only goal is to " <>
              "transform the success value.",
          example: """
          ```elixir
          # before
          case fetch(id) do
            {:ok, order} -> {:ok, order.total}
            {:error, _} = e -> e
          end

          # after
          with {:ok, order} <- fetch(id), do: {:ok, order.total}
          ```
          """,
          applies_when: "The transform is a single expression with no further branching."
        ),
        Fix.new(
          summary: "Extract a `Result.map/2` helper",
          detail:
            "If this shape recurs, define `Result.map/2` once and reuse it. " <>
              "Communicates intent at every call site.",
          example: """
          ```elixir
          # helper (define once)
          def map({:ok, v}, fun), do: {:ok, fun.(v)}
          def map({:error, _} = e, _fun), do: e

          # call site
          fetch(id) |> Result.map(& &1.total)
          ```
          """,
          applies_when: "The pattern recurs in 3+ places."
        )
      ],
      file: file,
      line: line
    )
  end
end
