defmodule Archdo.Rules.CE.MagicLiterals do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-17. The same magic value (number,
  # string, atom) compared or assigned in two or more modules without
  # a shared symbolic constant. Connascence of meaning across modules
  # at the longest distance: every consumer must know the magic
  # value's meaning out-of-band; renaming or renumbering forces a
  # search-and-replace across modules.

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "CE-17"

  @impl true
  def description,
    do: "Same magic value compared or assigned in 2+ modules without a shared symbolic constant"

  # Stable numeric constants that don't merit symbolic naming.
  @stable_numeric MapSet.new([
                    0,
                    1,
                    -1,
                    2,
                    100,
                    200,
                    201,
                    204,
                    301,
                    302,
                    400,
                    401,
                    403,
                    404,
                    500,
                    80,
                    443,
                    1000,
                    1024
                  ])

  # Status-shaped field names — atoms assigned to these in struct/map
  # updates count as cross-module magic-meaning evidence.
  @status_keys ~w(status state kind type role mode phase stage)a

  @doc """
  Project-level analysis. Returns one Diagnostic per cross-module
  magic-value cluster.
  """
  @spec analyze_project([{String.t(), Macro.t()}]) :: [Diagnostic.t()]
  def analyze_project(file_asts) do
    production_asts = Enum.reject(file_asts, fn {file, _} -> AST.test_file?(file) end)

    occurrences = collect_occurrences(production_asts)

    occurrences
    |> Enum.group_by(fn {value, _module, _file, _line} -> value end)
    |> Enum.flat_map(fn {value, occs} ->
      modules = occs |> Enum.map(fn {_, m, _, _} -> m end) |> Enum.uniq()

      case length(modules) >= 2 do
        true -> [build_diagnostic(value, occs)]
        false -> []
      end
    end)
  end

  # --- occurrence collection ---

  defp collect_occurrences(file_asts) do
    Enum.flat_map(file_asts, fn {file, ast} ->
      module = AST.extract_module_name(ast)

      ast
      |> find_magic_values()
      |> Enum.map(fn {value, line} -> {value, module, file, line} end)
    end)
  end

  defp find_magic_values(ast) do
    {_, found} =
      Macro.prewalk(ast, [], fn node, acc ->
        case extract_magic(node) do
          [] -> {node, acc}
          values -> {node, values ++ acc}
        end
      end)

    found
  end

  # `x == :magic` / `x != :magic` — comparison side. The literal is
  # most often on the right; if both sides are literals (rare), only
  # the rhs is examined to keep a single occurrence per node.
  defp extract_magic({:==, meta, [_lhs, rhs]}), do: extract_one(rhs, meta)
  defp extract_magic({:!=, meta, [_lhs, rhs]}), do: extract_one(rhs, meta)

  # Status-field assignment: `%{status: :magic}` or `%{m | status: :magic}`
  defp extract_magic({status_key, value})
       when is_atom(status_key) and status_key in @status_keys do
    extract_one(value, [])
  end

  defp extract_magic({{:__block__, _, [status_key]}, value})
       when is_atom(status_key) and status_key in @status_keys do
    extract_one(value, [])
  end

  defp extract_magic(_), do: []

  defp extract_one({:__block__, meta, [value]}, _outer_meta) when is_atom(value) do
    case magic_atom?(value) do
      true -> [{value, AST.line(meta)}]
      false -> []
    end
  end

  defp extract_one({:__block__, meta, [value]}, _outer_meta)
       when is_integer(value) do
    case MapSet.member?(@stable_numeric, value) do
      true -> []
      false -> [{value, AST.line(meta)}]
    end
  end

  defp extract_one(value, meta)
       when is_atom(value) and not is_nil(value) and not is_boolean(value) do
    case magic_atom?(value) do
      true -> [{value, AST.line(meta)}]
      false -> []
    end
  end

  defp extract_one(value, meta) when is_integer(value) do
    case MapSet.member?(@stable_numeric, value) do
      true -> []
      false -> [{value, AST.line(meta)}]
    end
  end

  defp extract_one(_, _), do: []

  # An atom is "magic" when it looks like a status code: not a tag
  # (:ok, :error), not nil, not a boolean, not a Module name. Atoms
  # like :pending_approval, :active, :paid count.
  defp magic_atom?(value) do
    name = Atom.to_string(value)

    cond do
      value in [:ok, :error, nil, true, false, nil] -> false
      String.starts_with?(name, "Elixir.") -> false
      String.length(name) < 4 -> false
      true -> true
    end
  end

  # --- diagnostic ---

  defp build_diagnostic(value, occs) do
    modules = occs |> Enum.map(fn {_, m, _, _} -> m end) |> Enum.uniq() |> Enum.sort()
    {_, _, primary_file, primary_line} = hd(occs)

    Diagnostic.warning("CE-17",
      title: "Magic value used across modules without a shared symbolic constant",
      message:
        "Value #{inspect(value)} appears as a magic literal across " <>
          "#{length(modules)} modules — #{Enum.join(modules, ", ")} — without a " <>
          "shared symbolic constant",
      why:
        "Connascence of meaning across modules is one of the strongest forms of " <>
          "coupling at the longest distance. Every consumer must know the magic " <>
          "value's meaning out-of-band; renaming or renumbering forces a " <>
          "search-and-replace; missing one site is a silent bug.",
      alternatives: [
        Fix.new(
          summary: "Introduce a shared symbolic constant",
          detail:
            "Define a module attribute, a `defenum`, or a behaviour-constant " <>
              "function exposing the value: `def status_pending_approval, do: " <>
              "#{inspect(value)}`. Replace literal references with the symbolic " <>
              "name.",
          applies_when: "The value represents a domain concept the codebase agrees on."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-17"],
      context: %{value: inspect(value), modules: modules},
      file: primary_file,
      line: primary_line
    )
  end
end
