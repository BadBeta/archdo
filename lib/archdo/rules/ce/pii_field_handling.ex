defmodule Archdo.Rules.CE.PiiFieldHandling do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-51. Schema fields whose names match
  # PII patterns (email, phone, ssn, *_token, password*, address,
  # etc.) without `@derive {Inspect, except: [...]}` excluding them.
  # PII leaks via inspect output in error messages, :observer,
  # telemetry payloads, crash dumps, and Repo query logging — the
  # default Inspect impl reveals every field.

  alias Archdo.{AST, Diagnostic, Fix, PiiSchema}

  @impl true
  def id, do: "CE-51"

  @impl true
  def description, do: "Ecto schema PII fields not excluded from Inspect derivation"

  @impl true
  def pack, do: :ce_privacy

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc "Project-level. One Diagnostic per schema with unprotected PII fields."
  @spec analyze_project([{String.t(), Macro.t()}], keyword()) :: [Diagnostic.t()]
  def analyze_project(file_asts, _opts \\ []) do
    file_asts
    |> Enum.reject(fn {file, _} -> AST.test_file?(file) end)
    |> Enum.flat_map(&module_diagnostics/1)
  end

  defp module_diagnostics({file, ast}) do
    cond do
      pii_handled_marker?(ast) ->
        []

      true ->
        case PiiSchema.schema_info(ast) do
          nil -> []
          info -> maybe_diagnostic(file, ast, info)
        end
    end
  end

  defp pii_handled_marker?(ast) do
    AST.contains?(ast, fn
      {:@, _, [{:archdo_pii_handled, _, _}]} -> true
      _ -> false
    end)
  end

  defp maybe_diagnostic(file, ast, %{pii_fields: pii} = info) do
    excepted = collect_inspect_excepts(ast)
    unprotected = pii -- excepted

    case unprotected do
      [] -> []
      list -> [build_diagnostic(file, info, list)]
    end
  end

  # Find @derive {Inspect, except: [:a, :b]} declarations and return
  # the union of all `except:` field lists.
  defp collect_inspect_excepts(ast) do
    {_, set} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:@, _, [{:derive, _, [arg]}]} = node, acc ->
          {node, MapSet.union(acc, derive_excepts(arg))}

        node, acc ->
          {node, acc}
      end)

    MapSet.to_list(set)
  end

  # The arg may be wrapped under literal_encoder: a 2-tuple becomes
  # {:__block__, _, [{aliases, opts}]}. Unwrap before matching.
  defp derive_excepts({:__block__, _, [inner]}), do: derive_excepts(inner)

  defp derive_excepts({:{}, _, [{:__aliases__, _, [:Inspect]}, opts]}) when is_list(opts),
    do: opts_excepts(opts)

  defp derive_excepts({{:__aliases__, _, [:Inspect]}, opts}) when is_list(opts),
    do: opts_excepts(opts)

  defp derive_excepts(_), do: MapSet.new()

  defp opts_excepts(opts) do
    Enum.reduce(opts, MapSet.new(), fn
      {{:__block__, _, [:except]}, list_node}, acc ->
        MapSet.union(acc, list_to_atoms(list_node))

      {:except, list_node}, acc ->
        MapSet.union(acc, list_to_atoms(list_node))

      _, acc ->
        acc
    end)
  end

  defp list_to_atoms({:__block__, _, [list]}) when is_list(list), do: list_to_atoms(list)

  defp list_to_atoms(list) when is_list(list) do
    list
    |> Enum.map(&AST.unwrap_atom/1)
    |> Enum.filter(&is_atom/1)
    |> MapSet.new()
  end

  defp list_to_atoms(_), do: MapSet.new()

  defp build_diagnostic(file, %{module: module, table: table}, fields) do
    fields_str = fields |> Enum.sort() |> Enum.map_join(", ", &inspect/1)

    Diagnostic.warning("CE-51",
      title: "PII field without designated handling",
      message:
        "#{module} (table \"#{table}\"): #{length(fields)} PII field(s) not " <>
          "excluded from Inspect — #{fields_str}. Default Inspect reveals every " <>
          "field; PII leaks via logs, error messages, observer, telemetry.",
      why:
        "PII leaks via the most common breach surfaces: log lines, error " <>
          "messages, `inspect` in `:observer`, telemetry payloads, crash dumps, " <>
          "and Repo query logging. Ecto schemas' default `Inspect` impl reveals " <>
          "every field. The fix is one `@derive {Inspect, except: [...]}` line " <>
          "above `defstruct` / `schema`. Even when the schema is internal-only " <>
          "today, the line is cheap insurance against tomorrow's accidental log.",
      alternatives: [
        Fix.new(
          summary: "Add @derive {Inspect, except: [...]} excluding the PII fields",
          detail:
            "`@derive {Inspect, except: #{inspect(fields)}}` immediately before " <>
              "`schema \"...\" do`. Inspect output of the struct will now hide " <>
              "these fields, surfacing as `#MyApp.User<email: \"\#Inspect.Excluded\", ...>`.",
          applies_when: "The fields are PII the application does not need to display."
        ),
        Fix.new(
          summary: "Mark @archdo_pii_handled if the fields are intentionally public",
          detail:
            "If the fields are public-by-design (display profile, public registry " <>
              "entry, opt-in directory), declare it: `@archdo_pii_handled \"public " <>
              "profile fields\"` at module level.",
          applies_when: "The fields are deliberately exposed."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-51"],
      context: %{module: module, table: table, unprotected_fields: fields},
      file: file,
      line: 1
    )
  end
end
