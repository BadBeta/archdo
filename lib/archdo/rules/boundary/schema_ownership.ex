defmodule Archdo.Rules.Boundary.SchemaOwnership do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "1.5"

  @impl true
  def description, do: "Each Ecto schema has one owning context — no cross-context schema construction"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc """
  Project-level: scan ASTs to find real Ecto schemas, then look for
  cross-context construction (`%MyApp.Other.Schema{...}`) of those schemas.
  """
  def analyze_project(file_asts) do
    schemas = identify_real_schemas(file_asts)

    file_asts
    |> Enum.flat_map(fn {file, ast} ->
      caller_module = AST.extract_module_name(ast)
      find_cross_context_constructions(file, ast, caller_module, schemas)
    end)
    |> Enum.uniq_by(fn d -> {d.file, d.line, d.message} end)
  end

  # Find every module that has `use Ecto.Schema` or `embedded_schema do`
  defp identify_real_schemas(file_asts) do
    file_asts
    |> Enum.flat_map(fn {_file, ast} ->
      if ecto_schema?(ast) do
        [AST.extract_module_name(ast)]
      else
        []
      end
    end)
    |> MapSet.new()
  end

  defp ecto_schema?(ast) do
    AST.contains?(ast, fn
      {:use, _, [{:__aliases__, _, [:Ecto, :Schema]} | _]} -> true
      {:schema, _, [_ | _]} -> true
      {:embedded_schema, _, _} -> true
      _ -> false
    end)
  end

  defp find_cross_context_constructions(file, ast, caller_module, schemas) do
    AST.find_all(ast, fn
      # %Module.Schema{...} — only when parts are plain atoms
      {:%, _, [{:__aliases__, _, parts}, _]} when is_list(parts) ->
        if Enum.all?(parts, &is_atom/1) do
          target_name =
            parts |> Module.concat() |> Atom.to_string() |> String.replace_leading("Elixir.", "")

          MapSet.member?(schemas, target_name) and not in_same_context?(caller_module, target_name)
        else
          false
        end

      _ ->
        false
    end)
    |> Enum.uniq_by(fn {_, _, [{:__aliases__, _, parts}, _]} -> parts end)
    |> Enum.map(fn {_, meta, [{:__aliases__, _, parts}, _]} ->
      schema_name = Enum.join(parts, ".")
      owning_context = owning_context_of(schema_name)

      Diagnostic.info("1.5",
        title: "Cross-context schema construction",
        message: "#{caller_module} constructs %#{schema_name}{} which is owned by #{owning_context}",
        why:
          "Schemas describe the internal data shape of the context that owns them. When another context " <>
            "constructs that struct directly, it freezes the field set in two places — the owning context can " <>
            "no longer change the schema without breaking the caller. Worse, the caller bypasses any validation, " <>
            "cast, or computed fields the owning context applies through changesets.",
        alternatives: [
          Fix.new(
            summary: "Verify this isn't a fixture, factory, or seed file",
            detail:
              "Check whether the construction is inside a test fixture, ExMachina factory, or seed/migration " <>
                "script. Cross-context construction in those files is intentional and can be ignored.",
            applies_when: "Always do this first."
          ),
          Fix.new(
            summary: "Use the owning context's public API instead",
            detail:
              "Replace the direct struct construction with a call to a public function on #{owning_context} " <>
                "(e.g. `#{owning_context}.create_<thing>(attrs)`). The owning context handles validation and " <>
                "returns the canonical struct.",
            applies_when: "There is a public constructor function on the owning context."
          ),
          Fix.new(
            summary: "Add a public constructor to the owning context",
            detail:
              "If no public function exists, add one to #{owning_context} that takes plain attrs and returns " <>
                "a `{:ok, struct}` tuple after the standard validation pipeline. Update the caller to use it.",
            applies_when: "The owning context lacks a public constructor."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#1.5"],
        context: %{
          caller: caller_module,
          schema: schema_name,
          owning_context: owning_context
        },
        file: file,
        line: AST.line(meta)
      )
    end)
  end

  defp owning_context_of(schema_name) do
    parts = String.split(schema_name, ".")

    cond do
      length(parts) >= 3 -> parts |> Enum.take(2) |> Enum.join(".")
      true -> schema_name
    end
  end

  defp in_same_context?(caller, schema) do
    caller_top = caller |> String.split(".") |> Enum.take(2) |> Enum.join(".")
    schema_top = schema |> String.split(".") |> Enum.take(2) |> Enum.join(".")
    caller_top == schema_top
  end
end
