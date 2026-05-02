defmodule Archdo.Rules.CE.ErrorCategoryDrift do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-48. Error atoms inside `{:error, _}`
  # tuples that are clearly synonyms scattered across the codebase:
  # `:not_found`, `:no_user`, `:user_not_found`, `:resource_missing`,
  # all referring to the same conceptual failure. Consumers must
  # pattern-match on every variant; renaming requires coordinated
  # change. Reuses CE-26-style token-stem clustering, scoped to the
  # error half of `{:error, _}` returns.

  alias Archdo.{AST, Diagnostic, Fix, Naming}

  @min_cluster_distinct 3
  @min_cluster_modules 2

  @impl true
  def id, do: "CE-48"

  @impl true
  def description, do: "Error atoms scattered as synonyms across modules — error category drift"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc "Project-level. One Diagnostic per scattered error-atom cluster."
  @spec analyze_project([{String.t(), Macro.t()}], keyword()) :: [Diagnostic.t()]
  def analyze_project(file_asts, _opts \\ []) do
    file_asts
    |> Enum.reject(fn {file, _} -> AST.test_file?(file) end)
    |> collect_occurrences()
    |> Enum.group_by(fn {_atom, canon, _module, _file, _line} -> canon end)
    |> Enum.flat_map(fn {canon, occs} ->
      surfaces = occs |> Enum.map(fn {a, _, _, _, _} -> a end) |> Enum.uniq()
      modules = occs |> Enum.map(fn {_, _, m, _, _} -> m end) |> Enum.uniq()

      cond do
        length(surfaces) >= @min_cluster_distinct and length(modules) >= @min_cluster_modules ->
          [build_diagnostic(canon, surfaces, occs)]

        true ->
          []
      end
    end)
  end

  # Each occurrence: {atom, canonical_key, module, file, line}
  defp collect_occurrences(file_asts) do
    Enum.flat_map(file_asts, fn {file, ast} ->
      module = AST.extract_module_name(ast)

      ast
      |> find_error_atoms()
      |> Enum.flat_map(fn {atom, line} ->
        case canonical(atom) do
          nil -> []
          canon -> [{atom, canon, module, file, line}]
        end
      end)
    end)
  end

  # Walk the AST looking for `{:error, atom}` literal tuples. Handles
  # both bare and literal_encoder-wrapped shapes for `:error` and the
  # error atom itself.
  defp find_error_atoms(ast) do
    {_, found} =
      Macro.prewalk(ast, [], fn
        # literal_encoder shape: {{:__block__, _, [:error]}, {:__block__, _, [atom]}}
        {{:__block__, _, [:error]}, {:__block__, meta, [atom]}} = node, acc
        when is_atom(atom) and atom != nil ->
          {node, [{atom, line(meta)} | acc]}

        # bare shape: {:error, :atom}
        {:error, atom} = node, acc when is_atom(atom) and atom != nil ->
          {node, [{atom, 0} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp line(meta) when is_list(meta), do: Keyword.get(meta, :line, 0)
  defp line(_), do: 0

  # Stop words filtered out before clustering — they appear across
  # many error names without contributing to category meaning.
  @stop_words ~w(not no is an the of for and or to a)

  # Canonicalize an error atom to its single most-distinctive stem.
  # Pure token-set canonicalization (CE-26-style) misses real synonyms:
  # `:not_found`, `:user_not_found`, `:no_user_found` have different
  # token sets but cluster around "found" as the discriminating stem.
  # Picking the longest non-stop-word stem groups them correctly.
  #
  # Returns nil for atoms that don't have a meaningful distinctive stem
  # (single short token: `:ok`, `:nil`, `:invalid`).
  defp canonical(atom) do
    stems =
      atom
      |> Atom.to_string()
      |> String.downcase()
      |> String.split(~r/[\s._\-:\/]+/, trim: true)
      |> Enum.reject(&(&1 in @stop_words))
      |> Enum.map(&Naming.stem/1)
      |> Enum.reject(&(String.length(&1) < 3))

    case stems do
      [] -> nil
      _ -> Enum.max_by(stems, &String.length/1)
    end
  end

  defp build_diagnostic(canon, surfaces, occs) do
    surface_repr = surfaces |> Enum.sort() |> Enum.take(5) |> Enum.map_join(", ", &inspect/1)

    {_, _, _, file, line} = hd(occs)

    Diagnostic.warning("CE-48",
      title: "Error category drift",
      message:
        "Error atoms cluster around '#{canon}': #{length(surfaces)} synonyms across " <>
          "#{length(occs)} call sites — #{surface_repr}",
      why:
        "Consumers must pattern-match on every variant; adding a new variant " <>
          "breaks pattern-matching silently in consumers; the error taxonomy has " <>
          "no single source of truth. Renaming requires coordinated change across " <>
          "all call sites and all consumers.",
      alternatives: [
        Fix.new(
          summary: "Centralize the error taxonomy",
          detail:
            "Define a `MyApp.Errors` module with named atoms (or struct types) " <>
              "and route all callers through `MyApp.Errors.not_found()` or similar. " <>
              "One file owns the taxonomy; consumers depend on names, not strings.",
          applies_when: "The cluster is genuinely the same conceptual failure."
        ),
        Fix.new(
          summary: "Confirm the variants are distinct categories",
          detail:
            "If `:user_not_found` and `:order_not_found` are legitimately " <>
              "different categories that callers handle differently, the cluster " <>
              "is a false positive. Mark the cluster's call sites with " <>
              "`# archdo:allow CE-48 reason: ...`.",
          applies_when: "The variants encode meaningful distinctions, not synonyms."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-48"],
      context: %{
        canonical: canon,
        surface_count: length(surfaces),
        call_sites: length(occs),
        examples: surfaces |> Enum.sort() |> Enum.take(5)
      },
      file: file,
      line: line
    )
  end
end
