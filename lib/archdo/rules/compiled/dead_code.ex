defmodule Archdo.Rules.Compiled.DeadCode do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.Compiled
  alias Archdo.{Diagnostic, Fix}

  @impl true
  def id, do: "6.24"

  @impl true
  def description, do: "Public function exported but never called — dead code"

  # Per-file analysis returns nothing — this rule requires compiled beam data
  @doc """
  Compiled-mode analysis using the interaction graph.
  """
  @spec analyze_compiled(Compiled.t()) :: [Diagnostic.t()]
  def analyze_compiled(graph), do: analyze_compiled(graph, [])

  @spec analyze_compiled(Compiled.t(), keyword()) :: [Diagnostic.t()]
  def analyze_compiled(graph, opts) do
    library_publics = Keyword.get(opts, :library_public_modules, MapSet.new())

    graph
    |> Compiled.dead_functions()
    |> Enum.reject(&function_in_public_library_module?(&1, library_publics))
    |> Enum.map(&build_diagnostic/1)
  end

  # Library mode: a "dead" public function in a public-API module is almost
  # certainly called by consumers Archdo can't see. Skip those findings.
  # The rule still fires on functions in `@moduledoc false` modules — those
  # are intentionally non-public and being unused inside the library is real.
  defp function_in_public_library_module?(%{module: module}, library_publics) do
    MapSet.member?(library_publics, module)
  end

  defp build_diagnostic(%{module: module, function: func, arity: arity}) do
    mod_name =
      module
      |> Atom.to_string()
      |> String.replace_leading("Elixir.", "")

    Diagnostic.info("6.24",
      title: "Dead public function",
      message:
        "#{mod_name}.#{func}/#{arity} is exported but never called from outside the module",
      why:
        "Public functions are part of the module's API contract. An exported function that " <>
          "nobody calls is dead weight — it increases the API surface callers must understand, " <>
          "survives refactors that should have removed it, and may mislead developers into " <>
          "thinking it's part of the supported interface. If it's truly unused, make it " <>
          "`defp` or delete it. If it's called dynamically (via apply/3 or protocol dispatch), " <>
          "the xref analysis may have missed it — verify before removing.",
      alternatives: [
        Fix.new(
          summary: "Make it private (defp) if only used internally",
          detail:
            "Change `def #{func}` to `defp #{func}`. The compiler will error if " <>
              "any external module tries to call it, confirming it's safe.",
          applies_when: "The function is used within the module but not outside."
        ),
        Fix.new(
          summary: "Delete if completely unused",
          detail:
            "Remove the function entirely. Run `mix compile` to verify nothing breaks. " <>
              "If it was called dynamically (apply/3, protocol dispatch), the compiler " <>
              "won't catch it — check at runtime too.",
          applies_when: "The function is not used anywhere."
        ),
        Fix.new(
          summary: "Keep and document if it's part of a public API",
          detail:
            "If the function is intentionally public for external consumers (library API, " <>
              "callback, or plugin hook), add @doc to document it and add a test that " <>
              "exercises it.",
          applies_when: "The function is called by consumers outside this project."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.24"],
      context: %{
        module: mod_name,
        function: "#{func}/#{arity}"
      },
      file: "lib",
      line: 0
    )
  end
end
