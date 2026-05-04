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

      case length(surfaces) >= @min_cluster_distinct and
             length(modules) >= @min_cluster_modules do
        true -> [build_diagnostic(canon, surfaces, occs)]
        false -> []
      end
    end)
  end

  # Each occurrence: {atom, canonical_key, module, file, line}
  defp collect_occurrences(file_asts) do
    Enum.flat_map(file_asts, fn {file, ast} ->
      module = AST.extract_module_name(ast)

      ast
      |> find_error_atoms()
      |> Enum.flat_map(&canonical_atom_entry(&1, module, file))
    end)
  end

  defp canonical_atom_entry({atom, line}, module, file) do
    case canonical(atom) do
      nil -> []
      canon -> [{atom, canon, module, file, line}]
    end
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
          {node, [{atom, AST.line(meta)} | acc]}

        # bare shape: {:error, :atom}
        {:error, atom} = node, acc when is_atom(atom) and atom != nil ->
          {node, [{atom, 0} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  # Stop words filtered out before clustering — they appear across
  # many error names without contributing to category meaning.
  @stop_words ~w(not no is an the of for and or to a)

  # Common "outcome" words shared by many distinct error categories.
  # `:file_not_found`, `:host_not_found`, `:link_not_found` are NOT
  # synonyms — they describe semantically distinct failures (filesystem
  # vs network vs URL). Filtered BEFORE stemming so atoms cluster only
  # on the WHAT (file / host / link / user), not the outcome word that
  # happens to be shared.
  @outcome_words ~w(
    found miss missing exist exists existed support supported supports
    supporting error errored invalid unknown allow allowed allowing
    forbidden allowed available avail unavailable timeout timed_out
    expired expire exceed exceeded fail failed failure success ok
    deleted deletion delete denied permitted refused rejected
    started starting started_already already
  )

  # Canonicalize an error atom to its sorted DISCRIMINATOR set —
  # the non-stop-word, non-outcome stems. Atoms cluster when their
  # discriminator sets match exactly:
  #
  #   :user_not_found, :no_user_found       → {user}     — cluster
  #   :file_not_found, :host_not_found      → {file}/{host} — DON'T cluster
  #   :not_found                            → {}          — excluded (no signal)
  #
  # Returns nil when the discriminator set is empty (the atom is pure
  # outcome words and contributes no clustering signal).
  defp canonical(atom) do
    parts =
      atom
      |> Atom.to_string()
      |> String.downcase()
      |> String.split(~r/[\s._\-:\/]+/, trim: true)

    discriminators =
      for part <- parts,
          part not in @stop_words,
          part not in @outcome_words,
          stem = Naming.stem(part),
          String.length(stem) >= 3,
          do: stem

    case discriminators do
      [] -> nil
      list -> list |> Enum.sort() |> Enum.uniq() |> Enum.join(",")
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
