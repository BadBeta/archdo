defmodule Archdo.Rules.Boundary.ParallelHierarchies do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{Diagnostic, Fix}

  # If a feature requires N+ parallel files, AND those files are too thin,
  # the parallel structure may be ceremonial rather than necessary.
  @min_thin_parallel 3
  @thin_node_threshold 30

  @impl true
  def id, do: "4.11"

  @impl true
  def description, do: "Parallel hierarchies — feature additions creating thin files in many directories"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc """
  Project-level: detect feature names that appear in 3+ parallel directories
  (commands/, events/, projections/, aggregates/) where the files are thin wrappers.
  """
  def analyze_project(file_asts) do
    # Group files by base name (last segment without extension)
    by_basename =
      file_asts
      |> Enum.group_by(fn {file, _ast} -> base_name(file) end)
      |> Enum.filter(fn {_name, files} -> length(files) >= @min_thin_parallel end)

    by_basename
    |> Enum.flat_map(fn {base, files_with_ast} ->
      directories = files_with_ast |> Enum.map(fn {f, _} -> directory(f) end) |> Enum.uniq()

      # Only flag if files are spread across distinct parallel-style directories
      if length(directories) >= @min_thin_parallel and parallel_dirs?(directories) do
        thin_files =
          files_with_ast
          |> Enum.filter(fn {_file, ast} -> ast_size(ast) < @thin_node_threshold end)

        if length(thin_files) >= @min_thin_parallel do
          {first_file, _} = hd(thin_files)
          locations = thin_files |> Enum.map(fn {f, _} -> Path.dirname(f) end) |> Enum.uniq()

          [
            Diagnostic.info("4.11",
              title: "Parallel hierarchy of thin files",
              message:
                "Feature \"#{base}\" appears as thin files in #{length(locations)} parallel directories: #{Enum.join(locations, ", ")}",
              why:
                "When adding a feature requires creating four near-empty files in parallel directories " <>
                  "(`commands/`, `events/`, `aggregates/`, `projections/`), the structure is paying tax for " <>
                  "every change. Each new file is mostly boilerplate that delegates to or wraps the others. " <>
                  "The parallel hierarchy may be defensive ceremony rather than a real organizational benefit — " <>
                  "every feature change ripples across all branches of the hierarchy.",
              alternatives: [
                Fix.new(
                  summary: "Flatten the hierarchy by feature",
                  detail:
                    "Group all files for one feature into one directory (`features/billing/{commands,events,aggregate,projection}.ex`) " <>
                      "instead of splitting by file type. Adding a feature touches one directory, not four.",
                  applies_when: "The parallel structure is by file type rather than feature."
                ),
                Fix.new(
                  summary: "Accept the hierarchy if the parallelism is essential",
                  detail:
                    "Some patterns (Commanded, hexagonal architecture) genuinely benefit from parallel " <>
                      "directories at scale. If your team is comfortable with the structure and the files are " <>
                      "thin because the framework demands it, document the choice and add to freeze.",
                  applies_when: "The framework demands this structure."
                )
              ],
              references: ["ARCHITECTURE_RULES.md#4.11"],
              context: %{feature: base, locations: locations},
              file: first_file,
              line: 1
            )
          ]
        else
          []
        end
      else
        []
      end
    end)
  end

  defp base_name(file) do
    file
    |> Path.basename(".ex")
    |> Path.basename(".exs")
  end

  defp directory(file) do
    file
    |> Path.dirname()
    |> Path.basename()
  end

  defp parallel_dirs?(dirs) do
    parallel_keywords = ~w(commands events aggregates projections handlers process_managers
                            views controllers schemas validators)

    Enum.count(dirs, fn d -> d in parallel_keywords end) >= 2
  end

  defp ast_size(nil), do: 0

  defp ast_size(ast) do
    {_, count} = Macro.prewalk(ast, 0, fn node, acc -> {node, acc + 1} end)
    count
  end
end
