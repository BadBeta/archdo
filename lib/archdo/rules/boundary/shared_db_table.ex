defmodule Archdo.Rules.Boundary.SharedDbTable do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — operational layer carve-out via Archdo.Phoenix.
  # data_migration scripts and Mix tasks often define a local schema mirroring
  # the real owning context's table — they aren't asserting separate ownership.

  alias Archdo.{AST, Diagnostic, Fix, Phoenix}

  @impl true
  def id, do: "1.31"

  @impl true
  def description, do: "Multiple schemas for the same database table — shared table ownership"

  # This is a project-level rule — needs all file ASTs
  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc """
  Project-level analysis: find database tables referenced by schemas
  in different contexts.
  """
  def analyze_project(file_asts) do
    # Collect all {table_name, context, file, line} tuples
    schemas =
      Enum.flat_map(file_asts, fn {file, ast} ->
        case Phoenix.operational?(Phoenix.classify_file(file, ast)) do
          true -> []
          false -> extract_schema_tables(file, ast)
        end
      end)

    # Group by table name, find tables with schemas in multiple contexts
    schemas
    |> Enum.group_by(fn {table, _ctx, _file, _line} -> table end)
    |> Enum.flat_map(fn {table, entries} ->
      contexts = Enum.uniq_by(entries, fn {_, ctx, _, _} -> ctx end)

      case length(contexts) > 1 do
        true ->
          Enum.map(entries, fn {_table, _ctx, file, line} ->
            context_names = Enum.map_join(contexts, ", ", fn {_, ctx, _, _} -> ctx end)
            build_diagnostic(file, line, table, context_names)
          end)

        false ->
          []
      end
    end)
  end

  defp extract_schema_tables(file, ast) do
    context = Phoenix.context_for_file(file)

    case context do
      nil ->
        []

      ctx ->
        Enum.map(
          AST.find_all(ast, fn
            {:schema, _, [table_name | _]} when is_binary(table_name) -> true
            {:schema, _, [{:__block__, _, [table_name]} | _]} when is_binary(table_name) -> true
            _ -> false
          end),
          fn {_, meta, [table_name | _]} ->
            table = unwrap_table(table_name)
            {table, ctx, file, AST.line(meta)}
          end
        )
    end
  end

  defp unwrap_table({:__block__, _, [name]}) when is_binary(name), do: name
  defp unwrap_table(name) when is_binary(name), do: name
  defp unwrap_table(_), do: nil

  defp build_diagnostic(file, line, table, contexts) do
    Diagnostic.warning("1.31",
      title: "Shared database table across contexts",
      message: "Table \"#{table}\" has schemas in multiple contexts: #{contexts}",
      why:
        "When two contexts both define Ecto schemas for the same database table, " <>
          "neither truly owns the data. Changes to the table structure require " <>
          "coordinating across context boundaries. This is invisible coupling " <>
          "through the database that defeats the purpose of context separation.",
      alternatives: [
        Fix.new(
          summary: "Designate one context as the table owner",
          detail:
            "One context owns the schema and provides a public API. " <>
              "Other contexts call the owning context's functions instead of " <>
              "querying the table directly.",
          applies_when: "One context is the natural owner of the data."
        ),
        Fix.new(
          summary: "Use a read-only view schema in the consuming context",
          detail:
            "If the consuming context needs a different view of the data, " <>
              "create a database view and a separate read-only schema for it.",
          applies_when: "The consuming context needs a subset or transformed view."
        )
      ],
      file: file,
      line: line
    )
  end
end
