defmodule Archdo.Rules.Module.WholeStructOneField do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.AST.Unwrap

  @impl true
  def id, do: "6.76"

  @impl true
  def description,
    do:
      "Destructuring whole struct (`%Mod{} = x`) when only one field is read — " <>
        "destructure the field directly"

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
        {def_kw, meta, [head, kw_or_body]} = node, acc when def_kw in @def_kws ->
          case maybe_violation(head, kw_or_body) do
            true -> {node, [AST.line(meta) | acc]}
            false -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.map(hits, fn line -> build_diagnostic(file, line) end)
  end

  defp maybe_violation(head, kw_or_body) do
    case head_struct_alias_var(head) do
      nil ->
        false

      {var_name, struct_alias} ->
        single_field_access?(extract_body(kw_or_body), var_name, struct_alias)
    end
  end

  # Head args contain a `%StructAlias{} = var_name` pattern (open
  # struct, no field bindings). Returns `{var_name, struct_alias}` or
  # `nil`.
  defp head_struct_alias_var({:when, _, [inner, _guard]}), do: head_struct_alias_var(inner)

  defp head_struct_alias_var({_name, _, args}) when is_list(args) do
    Enum.find_value(args, &struct_alias_var_pattern/1)
  end

  defp head_struct_alias_var(_), do: nil

  defp struct_alias_var_pattern(
         {:=, _,
          [
            {:%, _, [{:__aliases__, _, _alias}, {:%{}, _, []}]},
            {var, _, ctx}
          ]}
       )
       when is_atom(var) and is_atom(ctx),
       do: {var, :open}

  defp struct_alias_var_pattern(
         {:=, _,
          [
            {var, _, ctx},
            {:%, _, [{:__aliases__, _, _alias}, {:%{}, _, []}]}
          ]}
       )
       when is_atom(var) and is_atom(ctx),
       do: {var, :open}

  defp struct_alias_var_pattern(_), do: nil

  defp extract_body(kw) when is_list(kw) do
    case Unwrap.kw_get(kw, :do) do
      {:ok, body} -> body
      :error -> nil
    end
  end

  defp extract_body(body), do: body

  defp single_field_access?(nil, _, _), do: false

  defp single_field_access?(body, var_name, _struct_alias) do
    fields = collect_field_accesses(body, var_name)

    case fields do
      [_single] -> count_var_uses(body, var_name) == 1
      _ -> false
    end
  end

  # Walk body counting `var.field` accesses (returns list of fields)
  # and bare `var` references (so we can require single use).
  defp collect_field_accesses(body, var_name) do
    {_, fields} =
      Macro.prewalk(body, [], fn
        {{:., _, [{^var_name, _, _ctx}, field]}, _, _} = node, acc when is_atom(field) ->
          {node, [field | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(fields)
  end

  defp count_var_uses(body, var_name) do
    {_, count} =
      Macro.prewalk(body, 0, fn
        {^var_name, _, ctx} = node, acc when is_atom(ctx) -> {node, acc + 1}
        node, acc -> {node, acc}
      end)

    count
  end

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.76",
      title: "Whole-struct destructure when only one field is read",
      message:
        "This function head binds the entire struct (`%Mod{} = var`) but the body only " <>
          "accesses one field. Use head-pattern destructure for that single field instead.",
      why:
        "Head-pattern destructuring is more declarative than body field-access: it makes " <>
          "the function's input contract explicit and lets the reader see at a glance " <>
          "which fields the function depends on. Future readers don't have to scan the " <>
          "body to discover that only `id` is used.",
      alternatives: [
        Fix.new(
          summary: "Destructure the field in the head",
          detail:
            "def user_id(%User{id: id}), do: id\n" <>
              "# vs\n" <>
              "def user_id(%User{} = user), do: user.id",
          applies_when: "When the body reads exactly one field of the struct."
        )
      ],
      references: ["elixir-implementing/SKILL.md#2.3", "elixir-implementing/SKILL.md#5.2"],
      context: %{},
      file: file,
      line: line
    )
  end
end
