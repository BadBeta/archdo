defmodule Archdo.Rules.CE.ReturnShapeDrift do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-47. Mixed return-shape within a
  # context: a public function exists in the bang form (`name!/n`)
  # without a non-bang sibling. Callers are forced into rescue for
  # what looks like normal control flow; consumers don't know which
  # style to expect.
  #
  # v1 scope: detect bang-without-non-bang siblings within a single
  # module. The cross-context "ratio inconsistency" check from the
  # spec is fuzzy — deferred. Modules where ALL public functions are
  # bang are exempt (deliberate convention, e.g. seed scripts).
  #
  # Modules with fewer than 3 public functions are exempt — too small
  # a sample to claim a "context style."

  alias Archdo.{AST, Diagnostic, Fix}

  @min_context_size 3

  @impl true
  def id, do: "CE-47"

  @impl true
  def description,
    do: "Bang public function (name!/n) lacking a non-bang sibling — caller forced into rescue"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc "Project-level. One Diagnostic per orphan bang function."
  @spec analyze_project([{String.t(), Macro.t()}], keyword()) :: [Diagnostic.t()]
  def analyze_project(file_asts, _opts \\ []) do
    file_asts
    |> Enum.reject(fn {file, _} -> AST.test_file?(file) end)
    |> Enum.flat_map(&module_diagnostics/1)
  end

  defp module_diagnostics({file, ast}) do
    publics =
      ast
      |> AST.extract_functions(:public)
      # Drop dynamically-named functions (`def unquote(name)`) — name
      # isn't an atom, can't classify as bang/non-bang.
      |> Enum.filter(fn {n, _, _, _, _} -> is_atom(n) end)
      |> Enum.uniq_by(fn {n, a, _, _, _} -> {n, a} end)

    cond do
      length(publics) < @min_context_size ->
        []

      all_bang?(publics) ->
        []

      true ->
        find_orphan_bangs(file, ast, publics)
    end
  end

  defp all_bang?(publics) do
    Enum.all?(publics, fn {n, _, _, _, _} -> bang?(n) end)
  end

  # Function name may be a macro form like `unquote(name)` for
  # dynamically-defined functions. Skip non-atom names entirely.
  defp bang?(name) when is_atom(name) do
    name |> Atom.to_string() |> String.ends_with?("!")
  end

  defp bang?(_), do: false

  defp find_orphan_bangs(file, ast, publics) do
    # Use string-keyed set to avoid String.to_atom on the stripped base
    # name (which may not exist as an atom yet).
    name_arity_set =
      MapSet.new(publics, fn {n, a, _, _, _} -> {Atom.to_string(n), a} end)

    module = AST.extract_module_name(ast)

    publics
    |> Enum.filter(fn {n, _a, _, _, _} -> bang?(n) end)
    |> Enum.flat_map(fn {n, a, meta, _, _} ->
      base_str = strip_bang(n)

      case MapSet.member?(name_arity_set, {base_str, a}) do
        true -> []
        false -> [build_diagnostic(file, module, n, a, meta, base_str)]
      end
    end)
  end

  defp strip_bang(name) do
    name |> Atom.to_string() |> String.trim_trailing("!")
  end

  defp build_diagnostic(file, module, name, arity, meta, base) do

    Diagnostic.warning("CE-47",
      title: "Bang function without non-bang sibling",
      message:
        "#{module}.#{name}/#{arity}: bang form exists but #{base}/#{arity} doesn't. " <>
          "Callers wanting a tagged tuple are forced into rescue for normal control flow.",
      why:
        "The standard Elixir idiom: `name/n` returns `{:ok, v} | {:error, reason}` " <>
          "and `name!/n` raises. When only the bang form exists, callers either " <>
          "rescue (forcing exception flow for what may be a domain answer) or " <>
          "wrap the call themselves. Refactoring later silently breaks call sites " <>
          "that handled the other shape.",
      alternatives: [
        Fix.new(
          summary: "Add the non-bang sibling delegating from bang",
          detail:
            "Implement `def #{base}(args), do: {:ok, do_the_work(args)}` (or " <>
              "`{:ok, v}/{:error, reason}` shape per the operation), and have " <>
              "`#{name}` delegate: `def #{name}(args), do: case #{base}(args) do " <>
              "{:ok, v} -> v; {:error, e} -> raise translate(e) end`.",
          applies_when: "The operation has a meaningful tagged-tuple return for callers."
        ),
        Fix.new(
          summary: "Drop the bang if rescue isn't the right idiom",
          detail:
            "If callers should always handle failure, expose only the non-bang " <>
              "form. Bang variants are for fail-fast paths where the failure " <>
              "really is exceptional (programming error, missing config).",
          applies_when: "The bang form was added by reflex, not by need."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-47"],
      context: %{module: module, function: "#{name}/#{arity}", missing_sibling: "#{base}/#{arity}"},
      file: file,
      line: AST.line(meta)
    )
  end
end
