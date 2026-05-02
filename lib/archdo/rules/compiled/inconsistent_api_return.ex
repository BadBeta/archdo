defmodule Archdo.Rules.Compiled.InconsistentApiReturn do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Compiled.Graph
  alias Archdo.Rules.Compiled.Helpers

  @impl true
  def id, do: "6.28"

  @impl true
  def description, do: "Public API function returns inconsistent shapes across clauses"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  # Minimum clauses to check — single-clause functions always return one shape
  @min_clauses 2

  @spec analyze_compiled(Graph.t()) :: [Diagnostic.t()]
  def analyze_compiled(%Graph{beam_dir: beam_dir}) when is_binary(beam_dir) do
    beam_dir
    |> Graph.extract_function_clauses()
    |> Enum.flat_map(fn {module, functions} ->
      functions
      |> Enum.filter(fn fn_info ->
        fn_info.exported and
          fn_info.clause_count >= @min_clauses and
          not Helpers.framework_function?(fn_info.name) and
          not Helpers.generated_function?(fn_info.name)
      end)
      |> Enum.flat_map(fn fn_info ->
        case check_return_consistency(fn_info) do
          :consistent -> []
          {:inconsistent, shapes} -> [build_diagnostic(module, fn_info, shapes)]
        end
      end)
    end)
  end

  def analyze_compiled(_graph), do: []

  defp check_return_consistency(fn_info) do
    shapes =
      fn_info.clauses
      |> Enum.map(& &1.return_shape)
      |> Enum.reject(fn shape -> shape in [:unknown, :call, :variable] end)

    case shapes do
      [] ->
        :consistent

      _ ->
        normalized = Enum.map(shapes, &normalize_shape/1)
        unique = Enum.uniq(normalized)

        case length(unique) > 1 do
          true ->
            # Check if it's a valid ok/error pattern
            case valid_ok_error_pattern?(shapes) do
              true -> :consistent
              false -> {:inconsistent, shapes}
            end

          false ->
            :consistent
        end
    end
  end

  # Normalize shapes for comparison — tagged tuples with same tag are the same shape
  defp normalize_shape({:tagged_tuple, tag}), do: {:tagged_tuple, tag}
  defp normalize_shape({:atom, _}), do: :atom

  defp normalize_shape({:mixed, shapes}) do
    normalized =
      shapes
      |> Enum.map(&normalize_shape/1)
      |> Enum.sort()

    {:mixed, normalized}
  end

  defp normalize_shape(other), do: other

  # {:ok, _} and {:error, _} together is a valid pattern — not inconsistent
  defp valid_ok_error_pattern?(shapes) do
    tags =
      shapes
      |> Enum.flat_map(fn
        {:tagged_tuple, tag} ->
          [tag]

        {:mixed, inner} ->
          Enum.flat_map(inner, fn
            {:tagged_tuple, tag} -> [tag]
            _ -> []
          end)

        _ ->
          []
      end)
      |> MapSet.new()

    # Valid ok/error combinations
    MapSet.subset?(tags, MapSet.new([:ok, :error])) and MapSet.size(tags) > 0
  end

  defp build_diagnostic(module, fn_info, shapes) do
    mod_name = AST.module_name(module)

    shape_strs =
      shapes
      |> Enum.uniq()
      |> Enum.map_join(", ", &format_shape/1)

    Diagnostic.warning("6.28",
      title: "Inconsistent API return shapes",
      message:
        "#{mod_name}.#{fn_info.name}/#{fn_info.arity} returns different shapes: #{shape_strs}",
      why:
        "A public function that returns different shapes from different clauses " <>
          "forces callers to handle all possible shapes. This makes the API harder to use " <>
          "and more error-prone. Callers may assume one shape and crash on another. " <>
          "Consistent return shapes (e.g., always {:ok, _} | {:error, _}) make the " <>
          "API predictable and pattern-matchable.",
      alternatives: [
        Fix.new(
          summary: "Normalize all clauses to return the same shape",
          detail:
            "Ensure every clause of #{fn_info.name}/#{fn_info.arity} returns the " <>
              "same tagged tuple shape. Common patterns: {:ok, result} | {:error, reason}, " <>
              "or always return the same struct type.",
          applies_when: "The inconsistency is accidental."
        ),
        Fix.new(
          summary: "Document the return type with @spec",
          detail:
            "If different return shapes are intentional (e.g., returning different " <>
              "types for different inputs), document it with a clear @spec and @doc.",
          applies_when: "The varying return shapes are by design."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.28"],
      context: %{
        module: mod_name,
        function: "#{fn_info.name}/#{fn_info.arity}",
        shapes: shape_strs
      },
      file: "lib",
      line: 0
    )
  end

  defp format_shape({:tagged_tuple, tag}), do: "{:#{tag}, _}"
  defp format_shape({:atom, val}), do: ":#{inspect(val)}"
  defp format_shape(:map), do: "%{}"
  defp format_shape(:list), do: "[]"
  defp format_shape(:binary), do: "<<>>"
  defp format_shape(:integer), do: "integer"
  defp format_shape({:mixed, shapes}), do: "mixed(#{Enum.map_join(shapes, "|", &format_shape/1)})"
  defp format_shape(other), do: "#{inspect(other)}"
end
