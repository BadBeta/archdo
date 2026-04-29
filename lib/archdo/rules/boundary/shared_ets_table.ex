defmodule Archdo.Rules.Boundary.SharedEtsTable do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — operational layer carve-out via Archdo.Phoenix.
  # Mix tasks and release scripts touch ETS tables to bootstrap or backfill;
  # they aren't asserting separate ETS ownership.

  alias Archdo.{AST, Diagnostic, Fix, Phoenix}

  @impl true
  def id, do: "1.33"

  @impl true
  def description,
    do:
      "Multiple contexts access the same named ETS table directly — consider a shared API module"

  # Project-level rule
  @impl true
  def analyze(_file, _ast, _opts), do: []

  @ets_access_fns [
    :lookup,
    :insert,
    :delete,
    :select,
    :match,
    :update_element,
    :update_counter,
    :member,
    :info,
    :tab2list,
    :first,
    :next,
    :lookup_element
  ]

  def analyze_project(file_asts) do
    # Collect {table_name, context, file, line, operation} tuples
    accesses =
      Enum.flat_map(file_asts, fn {file, ast} ->
        case AST.test_file?(file) or
               Phoenix.operational?(Phoenix.classify_file(file, ast)) do
          true -> []
          false -> extract_ets_accesses(file, ast)
        end
      end)

    # Group by table name, find tables accessed from multiple contexts
    accesses
    |> Enum.group_by(fn {table, _ctx, _file, _line} -> table end)
    |> Enum.flat_map(fn {table, entries} ->
      contexts =
        entries
        |> Enum.map(fn {_, ctx, _, _} -> ctx end)
        |> Enum.uniq()

      case length(contexts) > 1 do
        true ->
          context_names = Enum.join(contexts, ", ")

          Enum.map(entries, fn {_table, _ctx, file, line} ->
            build_diagnostic(file, line, table, context_names)
          end)

        false ->
          []
      end
    end)
  end

  defp extract_ets_accesses(file, ast) do
    context = extract_context(file)

    case context do
      nil ->
        []

      ctx ->
        Enum.map(
          AST.find_all(ast, fn
            # :ets.lookup(:table_name, ...)
            {{:., _, [:ets, func]}, _, [{:__block__, _, [table_name]} | _]}
            when func in @ets_access_fns and is_atom(table_name) ->
              true

            {{:., _, [{:__block__, _, [:ets]}, func]}, _, [{:__block__, _, [table_name]} | _]}
            when func in @ets_access_fns and is_atom(table_name) ->
              true

            # :ets.lookup(table_name, ...) without literal_encoder wrapping
            {{:., _, [:ets, func]}, _, [table_name | _]}
            when func in @ets_access_fns and is_atom(table_name) ->
              true

            _ ->
              false
          end),
          fn {_, meta, [table_arg | _]} ->
            table = unwrap_atom(table_arg)
            {table, ctx, file, AST.line(meta)}
          end
        )
    end
  end

  defp unwrap_atom({:__block__, _, [atom]}) when is_atom(atom), do: atom
  defp unwrap_atom(atom) when is_atom(atom), do: atom
  defp unwrap_atom(_), do: :unknown

  defp extract_context(file) do
    case Regex.run(~r{lib/[^/]+/([^/]+)/}, file) do
      [_, context] -> Macro.camelize(context)
      _ -> nil
    end
  end

  defp build_diagnostic(file, line, table, contexts) do
    Diagnostic.info("1.33",
      title: "Shared ETS table across contexts",
      message: "ETS table :#{table} accessed directly from multiple contexts: #{contexts}",
      why:
        "Multiple contexts doing raw :ets calls on the same named table creates " <>
          "coupling through shared mutable state. This is fine if the table is " <>
          "managed by a dedicated shared module (cache, registry), but problematic " <>
          "if contexts read/write directly without a mediating API.",
      alternatives: [
        Fix.new(
          summary: "Each context owns its own ETS table",
          detail:
            "Give each context its own named ETS table. If data needs to cross " <>
              "boundaries, expose it through a public API function.",
          applies_when: "The contexts use the table for different purposes."
        ),
        Fix.new(
          summary: "Extract a shared cache module with a clear API",
          detail:
            "If the table genuinely serves multiple contexts (shared cache), " <>
              "extract it into a dedicated module with a typed public API " <>
              "that encapsulates the ETS access.",
          applies_when: "The table is a shared infrastructure concern."
        )
      ],
      file: file,
      line: line
    )
  end
end
