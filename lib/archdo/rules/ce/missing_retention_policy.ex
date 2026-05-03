defmodule Archdo.Rules.CE.MissingRetentionPolicy do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-52. Ecto schemas representing
  # user-generated data (timestamps + user-like FK) without a
  # retention policy: no `@retention` annotation, no scheduled
  # cleanup job referencing the table. Pack `:ce_privacy` — opt-in.
  #
  # v1 detection of "scheduled cleanup": any Oban.Worker module
  # containing the table name (string literal or atom). Quantum /
  # custom GenServer schedulers deferred to v2.

  alias Archdo.{AST, Diagnostic, Fix, IrreversibleDecision}

  defmodule SchemaInfo do
    @moduledoc """
    Internal struct used by MissingRetentionPolicy to bind a schema's
    table name with its declaring module. Defined as a nested
    defmodule rather than a private map so the struct shape is named
    in pattern matches and the type is checked at construction time.
    """
    defstruct [:table, :module]
  end

  # FK association names that count as "user-like" — schema is
  # considered user-generated data when belongs_to one of these.
  @user_fk_names ~w(user account member owner subject creator author actor)a

  @impl true
  def id, do: "CE-52"

  @impl true
  def description,
    do: "Ecto schema with user data (timestamps + user FK) lacks retention policy"

  @impl true
  def pack, do: :ce_privacy

  @doc "Project-level. One Diagnostic per user-data schema lacking retention."
  @spec analyze_project([{String.t(), Macro.t()}], keyword()) :: [Diagnostic.t()]
  def analyze_project(file_asts, _opts \\ []) do
    production = Enum.reject(file_asts, fn {file, _} -> AST.test_file?(file) end)

    cleaner_references = collect_cleaner_references(production)

    Enum.flat_map(production, fn {file, ast} ->
      case schema_info(ast, file, file_asts) do
        nil ->
          []

        info ->
          cond do
            referenced_by_cleaner?(info, cleaner_references) -> []
            AST.has_marker?(ast, :retention) -> []
            true -> [build_diagnostic(file, ast, info)]
          end
      end
    end)
  end

  defp referenced_by_cleaner?(%SchemaInfo{table: t, module: m}, refs) do
    MapSet.member?(refs, t) or MapSet.member?(refs, m) or
      MapSet.member?(refs, AST.short_name(m))
  end

  # Walk the AST looking for `schema "table_name" do ... end` blocks.
  # Returns nil if the module isn't a schema or doesn't have BOTH a
  # user-like FK AND timestamps.
  defp schema_info(ast, _file, _file_asts) do
    case find_schema_block(ast) do
      nil ->
        nil

      {table, schema_body} ->
        statements = AST.body_statements(schema_body)
        has_user_fk = Enum.any?(statements, &user_fk?/1)
        has_timestamps = Enum.any?(statements, &timestamps?/1)

        case has_user_fk and has_timestamps do
          true -> %SchemaInfo{table: table, module: AST.extract_module_name(ast)}
          false -> nil
        end
    end
  end

  defp find_schema_block(ast) do
    {_, found} =
      Macro.prewalk(ast, nil, fn
        node, found when found != nil ->
          {node, found}

        {:schema, _, [table_arg, kw]} = node, nil when is_list(kw) ->
          case AST.unwrap_string(table_arg) do
            nil ->
              {node, nil}

            table ->
              body = AST.do_body(kw)
              {node, {table, body}}
          end

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp user_fk?({:belongs_to, _, [name_arg | _]}) do
    a = AST.try_unwrap_atom(name_arg)
    a in @user_fk_names
  end

  defp user_fk?(_), do: false

  defp timestamps?({:timestamps, _, _}), do: true
  defp timestamps?(_), do: false

  # Set of names (string table names AND aliased module names) referenced
  # anywhere inside any Oban.Worker module. Conservative — false negatives
  # (worker references the schema indirectly) are preferred over false
  # positives (worker mentions the table in a docstring).
  defp collect_cleaner_references(file_asts) do
    file_asts
    |> Enum.flat_map(fn {_file, ast} ->
      case IrreversibleDecision.oban_worker?(ast) do
        true -> tables_referenced(ast) ++ aliases_referenced(ast)
        false -> []
      end
    end)
    |> MapSet.new()
  end

  defp aliases_referenced(ast) do
    {_, aliases} =
      Macro.prewalk(ast, [], fn
        {:__aliases__, _, parts} = node, acc when is_list(parts) ->
          # Only count if all parts are atoms (proper module ref)
          case Enum.all?(parts, &is_atom/1) do
            true ->
              joined = Enum.map_join(parts, ".", &Atom.to_string/1)
              last = parts |> List.last() |> Atom.to_string()
              {node, [joined, last | acc]}

            false ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    aliases
  end

  defp tables_referenced(ast) do
    {_, tables} =
      Macro.prewalk(ast, [], fn
        # Bare string literal: "table_name" — collect any string-shaped
        # value seen in the worker. Conservative: a worker mentioning
        # "sessions" probably touches sessions even via a query.
        {:__block__, _, [s]} = node, acc when is_binary(s) -> {node, [s | acc]}
        s = node, acc when is_binary(s) -> {node, [s | acc]}
        node, acc -> {node, acc}
      end)

    tables
  end

  defp build_diagnostic(file, ast, %{table: table}) do
    module = AST.extract_module_name(ast)

    Diagnostic.warning("CE-52",
      title: "Schema without retention policy",
      message:
        "#{module} (table \"#{table}\") holds user data (user-like FK + timestamps) " <>
          "but has no `@retention` annotation and no Oban worker references the " <>
          "table — unbounded growth risk and potential GDPR Art. 5(1)(e) issue.",
      why:
        "User-generated data schemas accumulate indefinitely without a deliberate " <>
          "retention policy. Operationally, tables grow until queries slow down " <>
          "or storage fills up. Under privacy law (GDPR Article 5(1)(e), CCPA " <>
          "§1798.105), unjustified indefinite retention is itself a compliance " <>
          "issue. The fix is one cron worker that prunes old records OR an " <>
          "explicit `@retention :forever, reason: ...` documenting intent.",
      alternatives: [
        Fix.new(
          summary: "Add an Oban worker that prunes records older than the retention window",
          detail:
            "`use Oban.Worker, queue: :cleanup` + `Repo.delete_all(from r in " <>
              "\"#{table}\", where: r.inserted_at < ago(@retention_days, \"day\"))`. " <>
              "Schedule via Oban.Plugins.Cron.",
          applies_when: "The data has a finite useful lifetime."
        ),
        Fix.new(
          summary: "Mark @retention to document intent",
          detail:
            "If the data must be retained indefinitely (audit log, financial " <>
              "compliance, regulatory requirement), declare it: `@retention " <>
              "\"forever — required for SOX audit trail\"` at module level.",
          applies_when: "Indefinite retention is justified by external requirement."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-52"],
      context: %{module: module, table: table},
      file: file,
      line: 1
    )
  end
end
