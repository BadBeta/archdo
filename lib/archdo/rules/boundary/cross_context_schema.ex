defmodule Archdo.Rules.Boundary.CrossContextSchema do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix, Phoenix}

  @impl true
  def id, do: "1.29"

  @impl true
  def description,
    do: "Schema struct from another context used directly — access through owning context API"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) or mix_file?(file) do
      true -> []
      false -> find_cross_context_schema_use(file, ast)
    end
  end

  defp find_cross_context_schema_use(file, ast) do
    own_context = Phoenix.context_for_file(file)

    case own_context do
      nil -> []
      ctx -> find_foreign_schema_refs(file, ast, ctx)
    end
  end

  defp find_foreign_schema_refs(file, ast, own_context) do
    Enum.map(
      AST.find_all(ast, fn
        # %OtherContext.Schema{} struct literal
        {:%, _, [{:__aliases__, _, aliases}, {:%{}, _, _}]} ->
          foreign_context_schema?(aliases, own_context)

        # %OtherContext.Schema{struct | field: val} update
        {:%, _, [{:__aliases__, _, aliases}, _]} ->
          foreign_context_schema?(aliases, own_context)

        _ ->
          false
      end),
      fn {_, meta, _} ->
        build_diagnostic(file, AST.line(meta), own_context)
      end
    )
  end

  # Check if aliases refer to a schema in a different context
  # Pattern: [:MyApp, :OtherContext, :Schema] where OtherContext != own context
  defp foreign_context_schema?(aliases, own_context)
       when is_list(aliases) and length(aliases) >= 3 do
    # Get the context portion (second element for MyApp.Context.Schema pattern)
    context_atom = Enum.at(aliases, 1)

    case is_atom(context_atom) do
      true ->
        foreign = Atom.to_string(context_atom)
        foreign != own_context and not infrastructure_module?(foreign)

      false ->
        false
    end
  end

  defp foreign_context_schema?(_, _), do: false

  # Infrastructure modules are shared — not a boundary violation
  defp infrastructure_module?(name) do
    name in [
      "Repo",
      "Mailer",
      "Endpoint",
      "Router",
      "Telemetry",
      "Application",
      "PubSub",
      "Presence",
      "Gettext",
      "Guardian",
      "Auth"
    ]
  end

  # Extract the context name from a file path
  # lib/my_app/accounts/user.ex → "Accounts"
  defp mix_file?(file), do: String.ends_with?(file, "mix.exs")

  defp build_diagnostic(file, line, own_context) do
    Diagnostic.info("1.29",
      title: "Cross-context schema access",
      message: "#{own_context} directly constructs or matches a schema from another context",
      why:
        "Constructing or pattern matching on another context's schema struct creates " <>
          "invisible coupling. If the schema changes fields, every cross-context usage " <>
          "breaks. Access data through the owning context's public API instead.",
      alternatives: [
        Fix.new(
          summary: "Call the owning context's API instead",
          detail:
            "Instead of `%OtherContext.Schema{field: val}`, call " <>
              "`OtherContext.get_thing(id)` and receive the data as a return value.",
          applies_when: "The struct is from a different bounded context."
        ),
        Fix.new(
          summary: "Define a shared type if both contexts need the shape",
          detail:
            "If the data genuinely crosses boundaries, define a shared struct " <>
              "or protocol that both contexts agree on.",
          applies_when: "The data is intentionally shared between contexts."
        )
      ],
      file: file,
      line: line
    )
  end
end
