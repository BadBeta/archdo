defmodule Archdo.Mcp.Tools.AnalyzeFile do
  @moduledoc false

  alias Archdo.Mcp.Encoder

  def name, do: "archdo_analyze_file"

  def description do
    "Analyze a single Elixir source string against per-file Archdo rules without writing it to disk. " <>
      "Use this to check code you are about to write or that the user has not yet saved. " <>
      "Note: cross-file/graph rules (1.1, 1.3, 8.4) cannot run on a single file and are skipped."
  end

  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "file" => %{
          "type" => "string",
          "description" =>
            "A virtual file path used for diagnostics (e.g. \"lib/my_app/foo.ex\"). The path is not read from disk."
        },
        "content" => %{
          "type" => "string",
          "description" => "The Elixir source code to analyze."
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
      "required" => ["file", "content"],
      "additionalProperties" => false
    }
  end

  def call(args) when is_map(args) do
    with {:ok, file} <- fetch(args, "file"),
         {:ok, content} <- fetch(args, "content"),
         {:ok, ast} <- parse(content, file) do
      opts =
        [only: list_or_nil(args["only"]), ignore: args["ignore"] || []]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      enabled_rules = filter_rules(opts)

      diagnostics =
        Enum.flat_map(enabled_rules, fn rule ->
          rule.analyze(file, ast, opts)
        end)

      {:ok, Encoder.encode_diagnostics(diagnostics)}
    end
  end

  defp fetch(args, key) do
    case Map.get(args, key) do
      nil -> {:error, "missing required argument `#{key}`"}
      "" -> {:error, "argument `#{key}` cannot be empty"}
      value -> {:ok, value}
    end
  end

  defp parse(content, file) do
    case Code.string_to_quoted(content,
           file: file,
           columns: true,
           token_metadata: true,
           literal_encoder: &{:ok, {:__block__, &2, [&1]}}
         ) do
      {:ok, ast} -> {:ok, ast}
      {:error, reason} -> {:error, "could not parse content: #{inspect(reason)}"}
    end
  end

  defp list_or_nil(nil), do: nil
  defp list_or_nil([]), do: nil
  defp list_or_nil(list) when is_list(list), do: list

  defp filter_rules(opts) do
    rules = Archdo.Runner.phase1_rules()

    case Keyword.get(opts, :only) do
      nil ->
        case Keyword.get(opts, :ignore) do
          nil -> rules
          [] -> rules
          ids -> Enum.reject(rules, &(&1.id() in ids))
        end

      ids ->
        Enum.filter(rules, &(&1.id() in ids))
    end
  end
end
