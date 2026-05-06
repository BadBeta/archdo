defmodule Archdo.Rules.Module.EctoFragmentStringInterpolation do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.92"

  @impl true
  def description,
    do:
      "`fragment/1,N` called with an interpolated string — SQL injection risk; " <>
        "use `fragment(\"... ?\", ^value)` parameterized form"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_unsafe_fragments(file, ast)
    end
  end

  defp find_unsafe_fragments(file, ast) do
    ast
    |> AST.find_all(&unsafe_fragment?/1)
    |> Enum.map(fn {_, meta, _} -> build_diagnostic(file, AST.line(meta)) end)
  end

  # `fragment("...#{var}...", _args)` — the first argument is a binary
  # AST node `{:<<>>, _, parts}` containing at least one non-binary
  # part (the interpolation).
  defp unsafe_fragment?({:fragment, _, [{:<<>>, _, parts} | _]}) when is_list(parts) do
    Enum.any?(parts, &interpolation_part?/1)
  end

  defp unsafe_fragment?(_), do: false

  defp interpolation_part?(p) when is_binary(p), do: false
  defp interpolation_part?({:"::", _, _}), do: true
  defp interpolation_part?(_), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.warning("6.92",
      title: "`fragment/N` with string interpolation — SQL injection",
      message:
        "`fragment(\"... \#{var} ...\")` interpolates `var` directly into the SQL " <>
          "string. If `var` ever holds attacker-controlled input, this is a SQL " <>
          "injection. Use the parameterized form `fragment(\"... ?\", ^var)` so " <>
          "Ecto sends `var` as a bound parameter — the database driver escapes it.",
      why:
        "Ecto's macro form of `fragment/N` is the only escape hatch from the safe " <>
          "query DSL into raw SQL. The PARAMETERIZED form (`fragment(\"col = ?\", " <>
          "^v)`) keeps you safe: the `?` placeholder is replaced by the database " <>
          "driver with a bound parameter, never by string concatenation. " <>
          "Interpolating with `\#{}` skips that safety entirely — the SQL string " <>
          "the database receives contains the user's input verbatim. Even " <>
          "\"trusted\" values (admin role names, internal IDs) drift over time; " <>
          "always parameterize.",
      alternatives: [
        Fix.new(
          summary: "Parameterize the fragment",
          detail:
            "from u in User, where: fragment(\"role = ?\", ^role)\n\n" <>
              "# For dynamic column names (which CAN'T be parameters), use a\n" <>
              "# whitelist that maps an atom to a known-safe column literal:\n" <>
              "@safe_cols ~w(name email role)a\n" <>
              "def by(col, val) when col in @safe_cols do\n" <>
              "  from u in User, where: field(u, ^col) == ^val\n" <>
              "end",
          applies_when: "Always — the parameterized form is faster too (statement caching)."
        )
      ],
      references: [
        "elixir-reviewing/security-audit-deep.md",
        "elixir-implementing/SKILL.md#7.7"
      ],
      context: %{},
      file: file,
      line: line
    )
  end
end
