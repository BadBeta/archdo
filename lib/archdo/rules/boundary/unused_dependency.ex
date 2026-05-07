defmodule Archdo.Rules.Boundary.UnusedDependency do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  # File.read! IS the boundary work — this rule reads source files
  # to detect unused alias declarations by string comparison. There
  # is no substitutability hole: the file content IS the input.
  Module.register_attribute(__MODULE__, :archdo_volatility, persist: true)
  @archdo_volatility :stable

  @impl true
  def id, do: "4.6"

  @impl true
  def description, do: "No unnecessary module dependencies"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      find_unused_aliases(file, ast)
    end
  end

  defp find_unused_aliases(file, ast) do
    # Collect all alias declarations
    aliases = collect_aliases(ast)
    # Get the full source as string to check usage
    source = File.read!(file)

    for {short_name, full, line} <- aliases,
        unused_alias?(source, short_name) do
      Diagnostic.info("4.6",
        title: "Unused alias",
        message: "alias #{full} is declared but #{short_name} is never referenced",
        why:
          "Unused aliases create phantom dependencies: the file declares it depends on the module but never " <>
            "actually calls it. They survive across refactors, accumulate over time, and make the dependency " <>
            "graph misleading. Removing them is free maintenance.",
        alternatives: [
          Fix.new(
            summary: "Delete the alias declaration",
            detail:
              "Remove the `alias #{full}` line. The compiler will warn (and Credo flags) if a real reference " <>
                "needed it; this rule has already determined it's unreferenced.",
            applies_when: "The alias is genuinely unused (the rule already verified)."
          ),
          Fix.new(
            summary: "Verify the alias isn't used in a sigil or string",
            detail:
              "The detection counts string occurrences. If the short name is used inside a sigil, heredoc, or " <>
                "template, the rule may flag it as unused. Double-check before deleting.",
            applies_when: "The module name appears in non-code contexts."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#4.6"],
        context: %{alias: full, short: short_name},
        file: file,
        line: line
      )
    end
  end

  # Count how many times the short name appears as a whole identifier
  # (NOT as a substring of another). `String.split(source, short_name)`
  # would count `CSV` inside `NimbleCSV` as a use — wrong. Use a regex
  # with word boundaries so `Helper` doesn't false-match `OtherHelper`,
  # `CSV` doesn't false-match `NimbleCSV`, etc. The alias declaration
  # itself contains the short name once (its own appearance), so the
  # threshold stays at "<= 1 means unused".
  defp unused_alias?(source, short_name) do
    pattern = ~r/\b#{Regex.escape(short_name)}\b/
    occurrences = Regex.scan(pattern, source) |> length()
    occurrences <= 1
  end

  defp collect_aliases(ast) do
    {_, aliases} =
      Macro.prewalk(ast, [], fn
        {:alias, meta, [{:__aliases__, _, parts} | opts]} = node, acc ->
          case AST.safe_concat(parts) do
            nil ->
              {node, acc}

            mod ->
              full = AST.module_name(mod)
              short = short_name(parts, opts)
              line = AST.line(meta)
              {node, [{short, full, line} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(aliases)
  end

  # `alias Foo.Bar, as: Baz` — the short name visible to source code
  # is `Baz`, NOT the last segment `Bar`. Without consulting the
  # `as:` opt, the rule grepped for `Bar` and flagged uses of `Baz`
  # as unused. Real-world: every `alias NimbleCSV.RFC4180, as: CSV`
  # was flagged as unused even when `CSV.parse_string/1` was used
  # downstream.
  defp short_name(parts, []), do: Atom.to_string(List.last(parts))

  defp short_name(parts, [opts]) when is_list(opts) do
    case extract_as_name(opts) do
      nil -> Atom.to_string(List.last(parts))
      as_name -> as_name
    end
  end

  defp short_name(parts, _), do: Atom.to_string(List.last(parts))

  defp extract_as_name(opts) do
    Enum.find_value(opts, fn
      # Bare keyword: `as: Baz`
      {:as, {:__aliases__, _, [as_name]}} when is_atom(as_name) ->
        Atom.to_string(as_name)

      # literal_encoder-wrapped: `{__block__-wrapped :as, alias}`
      {{:__block__, _, [:as]}, {:__aliases__, _, [as_name]}} when is_atom(as_name) ->
        Atom.to_string(as_name)

      _ ->
        nil
    end)
  end
end
