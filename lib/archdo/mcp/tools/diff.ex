defmodule Archdo.Mcp.Tools.Diff do
  @moduledoc false

  alias Archdo.Mcp.{Encoder, Helpers}
  alias Archdo.Runner

  def name, do: "archdo_diff"

  def description do
    "Analyze only files changed since a git ref. Returns only NEW findings " <>
      "on changed files. Essential for PR review — shows what architectural " <>
      "issues were introduced by the changes, not pre-existing debt."
  end

  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "paths" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Base paths to scope the analysis. Default: [\"lib\"]."
        },
        "ref" => %{
          "type" => "string",
          "description" =>
            "Git ref to diff against. Default: \"HEAD~1\". Use \"main\" for PR review."
        },
        "only" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Restrict to these rule IDs."
        },
        "ignore" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Skip these rule IDs."
        }
      },
      "additionalProperties" => false
    }
  end

  def call(args) when is_map(args) do
    base_paths = Map.get(args, "paths", ["lib"])
    ref = Map.get(args, "ref", "HEAD~1")

    case Archdo.GitDiff.changed_files(ref, base_paths) do
      {:ok, files} when files != [] ->
        opts = build_opts(args)
        diagnostics = Runner.analyze(files, opts)

        {:ok,
         %{
           ref: ref,
           changed_files: length(files),
           files: files,
           diagnostics: Encoder.encode_diagnostics(diagnostics)
         }}

      {:ok, []} ->
        {:ok,
         %{
           ref: ref,
           changed_files: 0,
           files: [],
           diagnostics: %{summary: %{total: 0}, diagnostics: []}
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_opts(args) do
    Enum.reject(
      [
        only: Helpers.list_or_nil(args["only"]),
        ignore: args["ignore"] || []
      ],
      fn {_k, v} -> is_nil(v) end
    )
  end
end
