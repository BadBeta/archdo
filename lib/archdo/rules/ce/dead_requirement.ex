defmodule Archdo.Rules.CE.DeadRequirement do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-33. A requirement listed in an
  # external requirements source (JSON file) with no referencing
  # `@requirement` / `@spec_ref` / `@trace` annotation in the code.
  # Closes the traceability loop CE-32 opens: every line of code
  # traces to a requirement (CE-32); every requirement traces to code
  # (CE-33). Without the reverse direction, requirements get
  # approved, planned, and silently forgotten.
  #
  # Pack: `:ce_compliance` — opt-in. Activated by passing
  # `requirements_source: "/path/to/reqs.json"` in opts.

  alias Archdo.{AST, Diagnostic, Fix, RequirementsSource}

  @trace_attrs [:requirement, :spec_ref, :trace]

  @impl true
  def id, do: "CE-33"

  @impl true
  def description,
    do: "Requirement listed in external source has no @requirement / @spec_ref / @trace in code"

  @impl true
  def pack, do: :ce_compliance

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc """
  Project-level. Off unless `requirements_source: <path>` in opts.
  Returns one Diagnostic per requirement present in the source but
  absent from any annotation across the codebase.
  """
  @spec analyze_project([{String.t(), Macro.t()}], keyword()) :: [Diagnostic.t()]
  def analyze_project(file_asts, opts \\ []) do
    diags_for_source(Keyword.get(opts, :requirements_source), file_asts)
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # the source path (nil vs binary) and the load result tag.
  defp diags_for_source(nil, _file_asts), do: []

  defp diags_for_source(path, file_asts) do
    diags_for_load(RequirementsSource.load(path), file_asts, path)
  end

  defp diags_for_load({:error, _}, _file_asts, _path), do: []

  defp diags_for_load({:ok, entries}, file_asts, path) do
    referenced_ids = collect_referenced_ids(file_asts)
    actionable = RequirementsSource.actionable_ids(entries)
    missing = MapSet.difference(actionable, referenced_ids)

    entries
    |> Enum.filter(fn %{id: id} -> MapSet.member?(missing, id) end)
    |> Enum.sort_by(& &1.id)
    |> Enum.map(&build_diagnostic(&1, path))
  end

  defp collect_referenced_ids(file_asts) do
    file_asts
    |> Enum.reject(fn {file, _} -> AST.test_file?(file) end)
    |> Enum.flat_map(fn {_file, ast} -> referenced_ids_in(ast) end)
    |> MapSet.new()
  end

  defp referenced_ids_in(ast) do
    {_, ids} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{name, _, [value]}]} = node, acc when name in @trace_attrs ->
          {node, extract_ids(value) ++ acc}

        node, acc ->
          {node, acc}
      end)

    ids
  end

  # Annotation values shapes:
  #   @requirement "REQ-1"             → string
  #   @requirement ["REQ-1", "REQ-2"]  → list of strings
  #   @trace ~w(REQ-1 ADR-2)           → list of atoms (sigil — runtime)
  #     parses as call to sigil_w; each element ends up an atom-or-string.
  defp extract_ids({:__block__, _, [s]}) when is_binary(s), do: [s]
  defp extract_ids(s) when is_binary(s), do: [s]

  defp extract_ids({:__block__, _, [list]}) when is_list(list),
    do: extract_ids(list)

  defp extract_ids(list) when is_list(list) do
    Enum.flat_map(list, &extract_ids/1)
  end

  # Atoms (from sigils or atom literals) — convert to string.
  defp extract_ids({:__block__, _, [a]}) when is_atom(a) and not is_nil(a) and not is_boolean(a),
    do: [Atom.to_string(a)]

  defp extract_ids(a) when is_atom(a) and not is_nil(a) and not is_boolean(a),
    do: [Atom.to_string(a)]

  # ~w(REQ-1 REQ-2) sigil call: {:sigil_w, _, [{:<<>>, _, [str]}, modifiers]}
  defp extract_ids({:sigil_w, _, [{:<<>>, _, [s]}, _modifiers]}) when is_binary(s) do
    String.split(s, ~r/\s+/, trim: true)
  end

  defp extract_ids(_), do: []

  defp build_diagnostic(%{id: id, status: status}, source_path) do
    status_str = if status, do: " (status: #{status})", else: ""

    Diagnostic.info("CE-33",
      title: "Dead requirement — listed in source but not referenced in code",
      message:
        "Requirement #{id}#{status_str} is in #{source_path} but no module has " <>
          "an `@requirement` / `@spec_ref` / `@trace` annotation referencing it.",
      why:
        "Closes the traceability loop CE-32 opens. CE-32 says 'every line of " <>
          "code traces to a requirement'; CE-33 says 'every requirement traces " <>
          "to code.' Without the reverse direction, requirements can be " <>
          "approved, planned, and forgotten without anyone noticing they were " <>
          "never implemented. The status field (cancelled / deferred / " <>
          "out_of_scope / not_in_scope) excludes a requirement from this rule.",
      alternatives: [
        Fix.new(
          summary: "Implement the requirement and add @requirement annotation",
          detail:
            "Add `@requirement \"#{id}\"` immediately above the implementing " <>
              "function (or at module level for module-wide implementations). The " <>
              "next CE-33 run will see the reference and stop firing.",
          applies_when: "The requirement is in scope and should be implemented."
        ),
        Fix.new(
          summary: "Mark the requirement as deferred / cancelled / out_of_scope",
          detail:
            "In #{source_path}, change the entry to object form with a status: " <>
              "`{\"id\": \"#{id}\", \"status\": \"deferred\"}`. CE-33's actionable " <>
              "filter excludes statuses cancelled / deferred / out_of_scope / " <>
              "not_in_scope.",
          applies_when: "The requirement is intentionally not implemented in this codebase."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-33"],
      context: %{requirement_id: id, status: status, source: source_path},
      file: source_path,
      line: 1
    )
  end
end
