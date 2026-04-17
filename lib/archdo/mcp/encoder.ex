defmodule Archdo.Mcp.Encoder do
  @moduledoc false

  alias Archdo.{Diagnostic, Fix}

  @doc """
  Convert a list of diagnostics into the MCP response payload:

      %{
        summary: %{errors: 1, warnings: 12, infos: 47, total: 60},
        diagnostics: [...]
      }
  """
  @spec encode_diagnostics([Archdo.Diagnostic.t()]) :: map()
  def encode_diagnostics(diagnostics) when is_list(diagnostics) do
    %{
      summary: summary(diagnostics),
      diagnostics: Enum.map(diagnostics, &diagnostic_to_map/1)
    }
  end

  @doc "Convert a single Diagnostic struct into a JSON-friendly map."
  @spec diagnostic_to_map(Archdo.Diagnostic.t()) :: map()
  def diagnostic_to_map(%Diagnostic{} = d) do
    %{
      rule_id: d.rule_id,
      severity: d.severity,
      title: d.title,
      message: d.message,
      why: d.why,
      alternatives: Enum.map(d.alternatives, &fix_to_map/1),
      references: d.references,
      context: stringify_context(d.context),
      file: d.file,
      line: d.line
    }
  end

  defp fix_to_map(%Fix{} = fix), do: Fix.to_map(fix)

  defp summary(diagnostics) do
    {errors, warnings, infos} =
      Enum.reduce(diagnostics, {0, 0, 0}, fn
        %{severity: :error}, {e, w, i} -> {e + 1, w, i}
        %{severity: :warning}, {e, w, i} -> {e, w + 1, i}
        %{severity: :info}, {e, w, i} -> {e, w, i + 1}
        _, acc -> acc
      end)

    %{errors: errors, warnings: warnings, infos: infos, total: errors + warnings + infos}
  end

  # Context maps may contain MapSets, atoms, or other Jason-unfriendly terms.
  # Walk the context recursively and coerce them into encodable shapes.
  defp stringify_context(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {k, encodable(v)} end)
  end

  defp stringify_context(other), do: encodable(other)

  defp encodable(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp encodable(%MapSet{} = set), do: set |> MapSet.to_list() |> Enum.map(&encodable/1)
  defp encodable(list) when is_list(list), do: Enum.map(list, &encodable/1)

  defp encodable(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {k, encodable(v)} end)

  defp encodable(value), do: value
end
