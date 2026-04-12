defmodule Archdo.Mcp.Tools.AnalyzePaths do
  @moduledoc false

  alias Archdo.Mcp.Encoder
  alias Archdo.Runner

  def name, do: "archdo_analyze_paths"

  def description do
    "Run Archdo against directories or files and return structured architectural diagnostics. " <>
      "Each diagnostic includes a title, why-it-matters explanation, ranked actionable fixes, " <>
      "and references back to the canonical rule documentation. Use this to check architecture " <>
      "of an existing Elixir project."
  end

  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "paths" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" =>
            "Directory or file paths to analyze. Directories are recursively scanned for *.ex/*.exs files."
        },
        "only" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" =>
            "Restrict the run to these rule IDs (e.g. [\"5.11\", \"8.2\"]). Omit to run every rule."
        },
        "ignore" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Skip these rule IDs."
        },
        "min_severity" => %{
          "type" => "string",
          "enum" => ["info", "warning", "error"],
          "description" =>
            "Drop diagnostics whose severity is below this level. Default: info (everything is returned)."
        },
        "boundaries" => %{
          "type" => "boolean",
          "description" =>
            "Include cross-file boundary/graph rules (1.1, 1.3, 1.4, 8.4, etc.). Slower but catches inter-module issues. Default: true."
        }
      },
      "required" => ["paths"],
      "additionalProperties" => false
    }
  end

  def call(args) when is_map(args) do
    with {:ok, paths} <- fetch_paths(args) do
      opts = build_opts(args)
      files = collect_files(paths)

      diagnostics =
        if Keyword.get(opts, :boundaries, true) do
          Runner.analyze_with_graph(files, opts)
        else
          Runner.analyze(files, opts)
        end

      filtered = filter_severity(diagnostics, args["min_severity"])
      {:ok, Encoder.encode_diagnostics(filtered)}
    end
  end

  defp fetch_paths(%{"paths" => paths}) when is_list(paths) and paths != [], do: {:ok, paths}
  defp fetch_paths(_), do: {:error, "missing or empty `paths` argument"}

  defp build_opts(args) do
    [
      only: list_or_nil(args["only"]),
      ignore: args["ignore"] || [],
      boundaries: Map.get(args, "boundaries", true)
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp list_or_nil(nil), do: nil
  defp list_or_nil([]), do: nil
  defp list_or_nil(list) when is_list(list), do: list

  defp collect_files(paths) do
    paths
    |> Enum.flat_map(fn path ->
      cond do
        File.regular?(path) ->
          [path]

        File.dir?(path) ->
          Path.wildcard(Path.join(path, "**/*.ex")) ++
            Path.wildcard(Path.join(path, "**/*.exs"))

        true ->
          []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp filter_severity(diagnostics, nil), do: diagnostics
  defp filter_severity(diagnostics, "info"), do: diagnostics

  defp filter_severity(diagnostics, "warning") do
    Enum.filter(diagnostics, &(&1.severity in [:warning, :error]))
  end

  defp filter_severity(diagnostics, "error") do
    Enum.filter(diagnostics, &(&1.severity == :error))
  end

  defp filter_severity(diagnostics, _), do: diagnostics
end
