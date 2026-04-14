defmodule Archdo.Mcp.Helpers do
  @moduledoc false

  @doc "Convert nil or empty list to nil, pass through non-empty lists."
  @spec list_or_nil(list() | nil) :: list() | nil
  def list_or_nil(nil), do: nil
  def list_or_nil([]), do: nil
  def list_or_nil(list) when is_list(list), do: list

  @doc "Filter diagnostics by minimum severity level."
  @spec filter_severity([Archdo.Diagnostic.t()], String.t() | nil) :: [Archdo.Diagnostic.t()]
  def filter_severity(diagnostics, nil), do: diagnostics
  def filter_severity(diagnostics, "info"), do: diagnostics

  def filter_severity(diagnostics, "warning") do
    Enum.filter(diagnostics, &(&1.severity in [:warning, :error]))
  end

  def filter_severity(diagnostics, "error") do
    Enum.filter(diagnostics, &(&1.severity == :error))
  end

  def filter_severity(diagnostics, _), do: diagnostics
end
