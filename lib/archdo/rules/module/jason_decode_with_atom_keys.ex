defmodule Archdo.Rules.Module.JasonDecodeWithAtomKeys do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.84"

  @impl true
  def description,
    do:
      "`Jason.decode!(body, keys: :atoms)` — atom-table exhaustion on untrusted JSON; " <>
        "use `:atoms!` (existing-only) or default string keys"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    Enum.map(AST.find_all(ast, &decode_with_atoms?/1), fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta))
    end)
  end

  # `Jason.decode!/2` or `Jason.decode/2` whose options keyword
  # contains `keys: :atoms`.
  defp decode_with_atoms?({{:., _, [{:__aliases__, _, [:Jason]}, fun]}, _, args})
       when fun in [:decode, :decode!] and is_list(args) do
    case List.last(args) do
      kw when is_list(kw) -> Keyword.get(kw, :keys) == :atoms
      _ -> false
    end
  end

  defp decode_with_atoms?(_), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.warning("6.84",
      title: "Jason.decode with `keys: :atoms` — atom-table exhaustion risk",
      message:
        "`Jason.decode(_, keys: :atoms)` converts every JSON key into an atom. The Erlang " <>
          "atom table is bounded (~1M atoms by default); untrusted input can exhaust it " <>
          "and crash the VM. Use `:atoms!` (only converts to existing atoms) or stay with " <>
          "the default string keys.",
      why:
        "Atoms are never garbage-collected. Once created they live for the BEAM process's " <>
          "lifetime. An attacker who can submit arbitrary JSON keys can issue a few thousand " <>
          "requests with unique keys to push the atom table toward its limit. The crash " <>
          "manifests as a SystemLimitError or the BEAM dying outright. `:atoms!` rejects " <>
          "unknown atoms (raises) instead of creating them — same convenience, no DoS surface.",
      alternatives: [
        Fix.new(
          summary: "Use `keys: :atoms!` (only converts to atoms that already exist)",
          detail:
            "Jason.decode!(body, keys: :atoms!)\n" <>
              "# Raises ArgumentError if the JSON contains an unknown key.\n" <>
              "# Pre-create the allowed atoms by referencing them anywhere in your code\n" <>
              "# (e.g., a module attribute listing the schema fields).",
          applies_when:
            "When the JSON's key set is known and bounded — the typical API-response case."
        ),
        Fix.new(
          summary: "Or stay with default string keys and convert at the boundary",
          detail:
            "body |> Jason.decode!() |> MyApp.Schema.cast()\n" <>
              "# Use Ecto changesets or a hand-written caster to validate AND convert.",
          applies_when:
            "When the input shape is open or when you want validation before conversion."
        )
      ],
      references: ["elixir-implementing/SKILL.md#7.7", "elixir-implementing/SKILL.md#2.5"],
      context: %{},
      file: file,
      line: line
    )
  end
end
