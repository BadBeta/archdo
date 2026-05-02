defmodule Archdo.PiiSchema do
  @moduledoc false

  # §§ elixir-planning: §6 — Group N foundation. Identifies Ecto
  # schemas that contain PII fields and reports which fields they are.
  # Shared by CE-51 (PII handling) and CE-53 (right-to-deletion path).

  alias Archdo.AST

  # Field-name patterns that indicate PII. Conservative defaults from
  # the rule spec — projects can extend via configuration.
  @pii_exact ~w(email phone ssn dob date_of_birth national_id tax_id address)a
  @pii_prefixes ["password", "passport"]
  @pii_suffixes ["_token"]

  @doc "Default PII pattern config — exposed for tests and tooling."
  def default_patterns,
    do: %{exact: @pii_exact, prefixes: @pii_prefixes, suffixes: @pii_suffixes}

  @doc """
  True when `field_name` matches any default PII pattern.
  """
  @spec pii_field?(atom()) :: boolean()
  def pii_field?(name) when is_atom(name) do
    s = Atom.to_string(name)

    name in @pii_exact or
      Enum.any?(@pii_prefixes, &String.starts_with?(s, &1)) or
      Enum.any?(@pii_suffixes, &String.ends_with?(s, &1))
  end

  def pii_field?(_), do: false

  @doc """
  Return `%{module, table, pii_fields}` for a schema AST when the
  schema declares at least one PII field. Returns `nil` for non-schema
  modules and for schemas with no PII fields.
  """
  @spec schema_info(Macro.t()) :: %{module: String.t(), table: String.t(), pii_fields: [atom()]} | nil
  def schema_info(ast) do
    case find_schema_block(ast) do
      nil ->
        nil

      {table, body} ->
        statements = body_statements(body)
        pii = Enum.flat_map(statements, &maybe_pii_field/1)

        case pii do
          [] -> nil
          fields -> %{module: AST.extract_module_name(ast), table: table, pii_fields: fields}
        end
    end
  end

  defp find_schema_block(ast) do
    {_, found} =
      Macro.prewalk(ast, nil, fn
        node, found when found != nil ->
          {node, found}

        {:schema, _, [table_arg, kw]} = node, nil when is_list(kw) ->
          case unwrap_string(table_arg) do
            nil -> {node, nil}
            table -> {node, {table, AST.do_body(kw)}}
          end

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp unwrap_string({:__block__, _, [s]}) when is_binary(s), do: s
  defp unwrap_string(s) when is_binary(s), do: s
  defp unwrap_string(_), do: nil

  defp body_statements({:__block__, _, statements}), do: statements
  defp body_statements(nil), do: []
  defp body_statements(single), do: [single]

  defp maybe_pii_field({:field, _, [name_arg | _]}) do
    case AST.unwrap_atom(name_arg) do
      a when is_atom(a) -> if pii_field?(a), do: [a], else: []
      _ -> []
    end
  end

  defp maybe_pii_field(_), do: []
end
