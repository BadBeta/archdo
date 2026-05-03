defmodule Archdo.Rules.Module.DuplicatedValidation do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix, Phoenix}

  @impl true
  def id, do: "3.6"

  @impl true
  def description, do: "Same validation rule should not appear in both web and domain layers"

  # Phoenix layers that count as the "web" side. Anything else (context,
  # schema, plain modules) is treated as domain.
  @web_layers ~w(web live_view component controller router)a
  @domain_layers ~w(context schema)a

  @doc """
  Project-level analysis. Walks every production file, classifies it as
  web or domain via `Archdo.Phoenix`, and collects function definitions
  whose name starts with `validate_`. A function name appearing in both
  layers is a duplicated validation: the web layer is asking the same
  question the domain already answers.
  """
  @spec analyze_project([{String.t(), Macro.t()}]) :: [Diagnostic.t()]
  def analyze_project(file_asts) do
    {web, domain} = aggregate(file_asts)

    web_set = MapSet.new(web, fn {_file, name} -> name end)
    domain_set = MapSet.new(domain, fn {_file, name} -> name end)
    duplicated = MapSet.intersection(web_set, domain_set)

    for name <- duplicated do
      {web_file, _} = Enum.find(web, fn {_file, n} -> n == name end)
      build_diagnostic(name, web_file)
    end
  end

  defp aggregate(file_asts) do
    Enum.reduce(file_asts, {[], []}, &aggregate_file/2)
  end

  defp aggregate_file({file, ast}, {web, domain}) do
    case AST.test_file?(file) do
      true ->
        {web, domain}

      false ->
        layer = Phoenix.classify_file(file, ast).layer
        validations = validations_in(ast, file)
        accumulate_by_layer(layer, validations, web, domain)
    end
  end

  defp accumulate_by_layer(layer, validations, web, domain) when layer in @web_layers,
    do: {validations ++ web, domain}

  defp accumulate_by_layer(layer, validations, web, domain) when layer in @domain_layers,
    do: {web, validations ++ domain}

  defp accumulate_by_layer(_layer, _validations, web, domain), do: {web, domain}

  # Collect every `def validate_X(...)` and `defp validate_X(...)` in the
  # file. Returns [{file, name}, ...]. Anonymous validators
  # (`validate_change(:email, fn ... end)`) are skipped — there's no
  # name to compare across layers, so cross-layer duplication isn't
  # detectable for that shape.
  defp validations_in(ast, file) do
    {_, names} =
      Macro.prewalk(ast, MapSet.new(), fn
        {kind, _, [{name, _, _args} | _]} = node, acc
        when kind in [:def, :defp] and is_atom(name) ->
          case validation_name?(name) do
            true -> {node, MapSet.put(acc, name)}
            false -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.map(names, &{file, &1})
  end

  defp validation_name?(name) do
    name_str = Atom.to_string(name)
    String.starts_with?(name_str, "validate_") and byte_size(name_str) > byte_size("validate_")
  end

  defp build_diagnostic(name, web_file) do
    Diagnostic.info("3.6",
      title: "Validation duplicated across layers",
      message: "Validation `#{name}/_` appears in both web and domain layers",
      why:
        "When the same validation rule lives in two layers, the web layer either silently diverges from " <>
          "the domain (so requests pass at the edge but fail later), or both layers stay in lockstep at the " <>
          "cost of duplicate maintenance for every rule change. Validation is a domain concern — the web " <>
          "layer should ask the domain whether the input is valid, not re-implement the check.",
      alternatives: [
        Fix.new(
          summary: "Move the validation to the domain changeset and have the web layer delegate",
          detail:
            "Keep all validation in the domain's changeset/changeset_for_X functions. Controllers and " <>
              "LiveViews build the changeset and call the context's create/update function. Errors come back " <>
              "from the domain — the web layer never re-validates.",
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
      context: %{validation: Atom.to_string(name)},
      file: web_file,
      line: 0
    )
  end
end
