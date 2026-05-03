defmodule Archdo.Mcp.Tools.Schemas do
  @moduledoc false

  # Shared MCP-tool input schemas. Several tools (`health`, `perf_audit`,
  # `stats`) accept exactly the same input shape — `{paths: [string]}`
  # with a default of `["lib"]`. Inlining the schema in each tool
  # produces byte-identical clones that drift independently when one
  # is updated.

  @doc """
  Schema for tools that accept a single `paths: [string]` input.
  """
  @spec paths_only(String.t()) :: map()
  def paths_only(description \\ "Paths to analyze. Default: [\"lib\"].") do
    %{
      "type" => "object",
      "properties" => %{
        "paths" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => description
        }
      },
      "additionalProperties" => false
    }
  end
end
