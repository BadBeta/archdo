defmodule Archdo.Rules.CE.MissingDeletionPath do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-53. PII-bearing schemas (the CE-51 set)
  # without a `delete_for_*`, `forget_*`, `anonymize_*`, or `erase_*`
  # function whose body references the schema. GDPR Article 17, CCPA
  # §1798.105, LGPD Article 18(VI) all require this path. Without an
  # explicit deletion / anonymization function, every subject deletion
  # request becomes ad-hoc engineering with non-uniform results.
  #
  # Opt-in: needs `gdpr_scope: true` in opts. Pack `:ce_privacy`.

  alias Archdo.{AST, Diagnostic, Fix, PiiSchema}

  # Function-name patterns recognized as deletion / anonymization paths.
  @deletion_prefixes ["delete_for_", "forget_", "anonymize_", "erase_"]

  @impl true
  def id, do: "CE-53"

  @impl true
  def description,
    do: "PII schema lacks right-to-deletion path (delete_for_*/forget_*/anonymize_*/erase_*)"

  @impl true
  def pack, do: :ce_privacy

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc "Project-level. Off unless `gdpr_scope: true` in opts."
  @spec analyze_project([{String.t(), Macro.t()}], keyword()) :: [Diagnostic.t()]
  def analyze_project(file_asts, opts \\ []) do
    case Keyword.get(opts, :gdpr_scope, false) do
      false ->
        []

      true ->
        production = Enum.reject(file_asts, fn {file, _} -> AST.test_file?(file) end)
        deletion_targets = collect_deletion_targets(production)

        Enum.flat_map(production, &maybe_diagnostic(&1, deletion_targets))
    end
  end

  defp maybe_diagnostic({file, ast}, deletion_targets) do
    cond do
      gdpr_exempt?(ast) ->
        []

      true ->
        case PiiSchema.schema_info(ast) do
          nil ->
            []

          info ->
            module = info.module

            cond do
              MapSet.member?(deletion_targets, module) -> []
              MapSet.member?(deletion_targets, last_segment(module)) -> []
              MapSet.member?(deletion_targets, info.table) -> []
              true -> [build_diagnostic(file, info)]
            end
        end
    end
  end

  defp gdpr_exempt?(ast) do
    AST.contains?(ast, fn
      {:@, _, [{:archdo_gdpr_exempt, _, _}]} -> true
      _ -> false
    end)
  end

  defp last_segment(name), do: name |> String.split(".") |> List.last()

  # Set of module / schema / table names referenced by any deletion-pattern
  # function across the project.
  defp collect_deletion_targets(file_asts) do
    file_asts
    |> Enum.flat_map(fn {_file, ast} ->
      ast
      |> AST.extract_functions(:public)
      |> Enum.flat_map(fn {name, _arity, _meta, _args, body} ->
        case is_atom(name) and deletion_prefix?(name) do
          true -> body && references_in(body)
          false -> []
        end
      end)
      |> Enum.reject(&is_nil/1)
    end)
    |> List.flatten()
    |> MapSet.new()
  end

  defp deletion_prefix?(name) do
    s = Atom.to_string(name)
    Enum.any?(@deletion_prefixes, &String.starts_with?(s, &1))
  end

  defp references_in(body) do
    {_, refs} =
      Macro.prewalk(body, [], fn
        # Module aliases — record both full name and last segment
        {:__aliases__, _, parts} = node, acc when is_list(parts) ->
          case Enum.all?(parts, &is_atom/1) do
            true ->
              full = parts |> Enum.map(&Atom.to_string/1) |> Enum.join(".")
              last = parts |> List.last() |> Atom.to_string()
              {node, [full, last | acc]}

            false ->
              {node, acc}
          end

        # String literals — could be a table name in a from clause
        {:__block__, _, [s]} = node, acc when is_binary(s) ->
          {node, [s | acc]}

        s = node, acc when is_binary(s) ->
          {node, [s | acc]}

        node, acc ->
          {node, acc}
      end)

    refs
  end

  defp build_diagnostic(file, %{module: module, table: table, pii_fields: fields}) do
    fields_str = fields |> Enum.sort() |> Enum.map_join(", ", &inspect/1)

    Diagnostic.warning("CE-53",
      title: "PII schema without right-to-deletion path",
      message:
        "#{module} (table \"#{table}\", PII: #{fields_str}): no `delete_for_*` / " <>
          "`forget_*` / `anonymize_*` / `erase_*` function references it. GDPR Art. " <>
          "17 / CCPA §1798.105 / LGPD Art. 18(VI) right-to-erasure paths missing.",
      why:
        "Without an explicit deletion / anonymization function, each subject " <>
          "deletion request becomes ad-hoc engineering with non-uniform results. " <>
          "Compliance regimes (GDPR, CCPA, LGPD) require this path; absence is a " <>
          "regulatory issue separate from the cost of bespoke implementation per " <>
          "request.",
      alternatives: [
        Fix.new(
          summary: "Implement delete_for_user/1 (or anonymize_user/1) in the owning context",
          detail:
            "Anonymization is preferable when foreign-key references prevent deletion: " <>
              "replace email/phone/name with deterministic hashes; preserve " <>
              "`inserted_at` for audit. Route the function from the user-account-" <>
              "deletion flow.",
          applies_when: "The schema must support GDPR Art. 17 / similar."
        ),
        Fix.new(
          summary: "Mark @archdo_gdpr_exempt if the schema is out-of-scope",
          detail:
            "If the schema is genuinely out-of-scope (employee data under separate " <>
              "legal basis, public profile data, anonymized analytics aggregates), " <>
              "declare it: `@archdo_gdpr_exempt \"reason\"` at module level.",
          applies_when: "The schema is intentionally out of GDPR scope."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-53"],
      context: %{module: module, table: table, pii_fields: fields},
      file: file,
      line: 1
    )
  end
end
