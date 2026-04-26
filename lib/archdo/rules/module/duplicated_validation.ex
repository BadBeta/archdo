defmodule Archdo.Rules.Module.DuplicatedValidation do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{Diagnostic, Fix}

  @impl true
  def id, do: "3.6"

  @impl true
  def description, do: "Same validation rule should not appear in both web and domain layers"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc """
  Project-level: compare validation patterns between web and domain modules.
  Takes lists of {file, validations} for each layer.
  """
  def analyze_project(web_validations, domain_validations) do
    # Find validation function names/patterns that appear in both layers
    web_set = MapSet.new(web_validations, fn {_, name} -> name end)
    domain_set = MapSet.new(domain_validations, fn {_, name} -> name end)

    duplicated = MapSet.intersection(web_set, domain_set)

    duplicated
    |> MapSet.to_list()
    |> Enum.map(fn name ->
      {web_file, _} = Enum.find(web_validations, fn {_, n} -> n == name end)

      Diagnostic.info("3.6",
        title: "Validation duplicated across layers",
        message: "Validation \"#{name}\" appears in both web and domain layers",
        why:
          "When the same validation rule lives in two layers, the web layer either silently diverges from " <>
            "the domain (so requests pass at the edge but fail later), or both layers stay in lockstep at the " <>
            "cost of duplicate maintenance for every rule change. Validation is a domain concern — the web " <>
            "layer should ask the domain whether the input is valid, not re-implement the check.",
        alternatives: [
          Fix.new(
            summary:
              "Move the validation to the domain changeset and have the web layer delegate",
            detail:
              "Keep all validation in the domain's changeset/changeset_for_X functions. Controllers and " <>
                "LiveViews build the changeset and call `Repo.insert/update` (or the context's create/update " <>
                "function). Errors come back from the domain — the web layer never re-validates.",
            applies_when: "The validation is a business rule, not a request format check."
          ),
          Fix.new(
            summary: "Keep edge validation only for request shape, not business rules",
            detail:
              "Web-layer validation should be limited to things like 'this field exists', 'this is JSON-decodable', " <>
                "'this query parameter is an integer'. Anything that depends on the domain (uniqueness, ranges, " <>
                "business invariants) lives only in the domain.",
            applies_when: "You need to keep the web check, but it's a different kind of check."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#3.6"],
        context: %{validation: name},
        file: web_file,
        line: 0
      )
    end)
  end
end
