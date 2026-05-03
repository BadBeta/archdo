defmodule Archdo.Rules.Compiled.InconsistentApiReturn do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Compiled
  alias Archdo.Rules.Compiled.Helpers

  @impl true
  def id, do: "6.28"

  @impl true
  def description, do: "Public API function returns inconsistent shapes across clauses"

  # Minimum clauses to check — single-clause functions always return one shape
  @min_clauses 2

  @spec analyze_compiled(Compiled.t()) :: [Diagnostic.t()]
  def analyze_compiled(graph) do
    case Compiled.beam_dir(graph) do
      beam_dir when is_binary(beam_dir) -> scan_beam_dir(beam_dir)
      _ -> []
    end
  end

  defp scan_beam_dir(beam_dir) do
    beam_dir
    |> Compiled.extract_function_clauses()
    |> Enum.flat_map(&module_fn_diags/1)
  end

  defp module_fn_diags({module, functions}) do
    functions
    |> Enum.filter(&candidate?/1)
    |> Enum.flat_map(&fn_diag(&1, module))
  end

  defp candidate?(fn_info) do
    fn_info.exported and
      fn_info.clause_count >= @min_clauses and
      not Helpers.framework_function?(fn_info.name) and
      not Helpers.generated_function?(fn_info.name)
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # the result of check_return_consistency.
  defp fn_diag(fn_info, module) do
    diag_for_consistency(check_return_consistency(fn_info), fn_info, module)
  end

  defp diag_for_consistency(:consistent, _fn_info, _module), do: []

  defp diag_for_consistency({:inconsistent, shapes}, fn_info, module),
    do: [build_diagnostic(module, fn_info, shapes)]

  defp check_return_consistency(fn_info) do
    shapes =
      fn_info.clauses
      |> Enum.map(& &1.return_shape)
      |> Enum.reject(fn shape -> shape in [:unknown, :call, :variable] end)

    consistency_for_shapes(shapes)
  end

  defp consistency_for_shapes([]), do: :consistent

  defp consistency_for_shapes(shapes) do
    unique = shapes |> Enum.map(&normalize_shape/1) |> Enum.uniq()
    consistency_if_unique(length(unique) > 1, shapes)
  end

  defp consistency_if_unique(false, _shapes), do: :consistent

  defp consistency_if_unique(true, shapes) do
    inconsistent_unless_ok_error(valid_ok_error_pattern?(shapes), shapes)
  end

  defp inconsistent_unless_ok_error(true, _shapes), do: :consistent
  defp inconsistent_unless_ok_error(false, shapes), do: {:inconsistent, shapes}

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
      |> Enum.flat_map(&extract_tags/1)
      |> MapSet.new()

    # Valid ok/error combinations
    MapSet.subset?(tags, MapSet.new([:ok, :error])) and MapSet.size(tags) > 0
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # the shape tuple ({:tagged_tuple, _} / {:mixed, inner} / other).
  defp extract_tags({:tagged_tuple, tag}), do: [tag]
  defp extract_tags({:mixed, inner}), do: Enum.flat_map(inner, &inner_tag/1)
  defp extract_tags(_), do: []

  defp inner_tag({:tagged_tuple, tag}), do: [tag]
  defp inner_tag(_), do: []

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
