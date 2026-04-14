defmodule Archdo.Mcp.Tools.DeepReview do
  @moduledoc false

  alias Archdo.Mcp.{Encoder, Helpers, ReviewHints}
  alias Archdo.Runner

  def name, do: "archdo_deep_review"

  def description do
    "Run Archdo's static analysis AND generate a structured review plan for the LLM to investigate " <>
      "deeper architectural issues that AST analysis cannot catch. Returns two sections: " <>
      "(1) `diagnostics` — the static findings, same as archdo_analyze_paths; " <>
      "(2) `review_plan` — a prioritized list of investigation items with specific questions to answer, " <>
      "files to read, and what triggered the investigation. " <>
      "Use this instead of archdo_analyze_paths when the user asks for a comprehensive architectural review. " <>
      "After receiving the response, READ the files listed in each review_plan item and answer the questions. " <>
      "The static findings tell you what the code LOOKS LIKE; the review plan tells you what to investigate " <>
      "about what it MEANS."
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
          "description" => "Restrict static analysis to these rule IDs. The review plan is always generated from whatever findings exist."
        },
        "ignore" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Skip these rule IDs in static analysis."
        },
        "min_severity" => %{
          "type" => "string",
          "enum" => ["info", "warning", "error"],
          "description" => "Drop diagnostics below this severity. Default: info."
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

      # Run static analysis (same as analyze_paths)
      diagnostics = Runner.analyze_with_graph(files, opts)
      filtered = Helpers.filter_severity(diagnostics, args["min_severity"])

      # Generate the review plan from the findings
      review_plan = ReviewHints.generate(filtered, paths: paths)

      {:ok,
       %{
         diagnostics: Encoder.encode_diagnostics(filtered),
         review_plan: format_review_plan(review_plan),
         instructions:
           "TWO-LAYER REVIEW. The `diagnostics` section is Layer 1 (static findings). " <>
             "The `review_plan` is Layer 2 (investigation + fixes). For each review_plan item: " <>
             "(1) read the files listed in `files_to_read`, " <>
             "(2) for each item in `investigate`, answer the `question` by reading the code, " <>
             "(3) if the answer is YES, apply the fix described in `if_confirmed` — it includes " <>
             "the specific code pattern to use. If `example` is present, adapt it to the project. " <>
             "Prioritize by `priority` (1 = critical). Report what you found and what you fixed."
       }}
    end
  end

  defp format_review_plan(items) do
    items
    |> Enum.with_index(1)
    |> Enum.map(fn {item, idx} ->
      base = %{
        index: idx,
        category: item.category,
        priority: item.priority,
        triggered_by: item.triggered_by,
        files_to_read: item.files
      }

      # New format: investigate items with question + if_confirmed + optional example
      case Map.get(item, :investigate) do
        nil ->
          # Legacy format fallback (shouldn't happen but safe)
          Map.put(base, :investigate, format_legacy_questions(Map.get(item, :questions, [])))

        investigate when is_list(investigate) ->
          Map.put(base, :investigate, Enum.map(investigate, &format_investigate_item/1))
      end
    end)
  end

  defp format_investigate_item(%{question: q, if_confirmed: fix} = item) do
    result = %{question: q, if_confirmed: fix}

    case Map.get(item, :example) do
      nil -> result
      "" -> result
      example -> Map.put(result, :example, example)
    end
  end

  defp format_legacy_questions(questions) do
    Enum.map(questions, fn q ->
      %{question: q, if_confirmed: "Investigate and fix based on the finding."}
    end)
  end

  defp fetch_paths(%{"paths" => paths}) when is_list(paths) and paths != [], do: {:ok, paths}
  defp fetch_paths(_), do: {:error, "missing or empty `paths` argument"}

  defp build_opts(args) do
    [
      only: Helpers.list_or_nil(args["only"]),
      ignore: args["ignore"] || [],
      boundaries: true
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp collect_files(paths), do: Archdo.collect_files(paths)
end
