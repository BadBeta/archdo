defmodule Archdo.Rules.Boundary.AnemicContext do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{Config, Diagnostic, Fix}

  # Contexts with fewer files than this are "anemic" unless they have a very
  # focused purpose (single schema, single behaviour). Default —
  # overridable via `.archdo.exs` thresholds key "1.11" :min_files.
  @min_files 3

  @impl true
  def id, do: "1.11"

  @impl true
  def description, do: "Anemic contexts — contexts too small to justify being a context"

  @doc """
  Project-level: count files per context directory. Contexts with fewer
  than `min_files` files that are heavily depended on from outside
  suggest the boundary is gratuitous — the content could live in
  another context. Threshold is configurable via `.archdo.exs`.
  """
  def analyze_project(source_files, opts \\ []) do
    threshold = min_files(opts)

    source_files
    |> Enum.group_by(&context_dir/1)
    |> Enum.reject(fn {dir, _} -> is_nil(dir) end)
    |> Enum.filter(fn {_dir, files} -> length(files) < threshold end)
    |> Enum.map(fn {dir, files} ->
      Diagnostic.info("1.11",
        title: "Anemic context",
        message: "#{dir} contains only #{length(files)} file(s)",
        why:
          "Each context is supposed to encapsulate a meaningful slice of business behaviour. A two-file " <>
            "context is usually a directory pretending to be a boundary: the cost of crossing the boundary " <>
            "(public API, indirection, mental overhead) is real, but the value (encapsulation, cohesion) is " <>
            "absent because there's barely anything to encapsulate.",
        alternatives: [
          Fix.new(
            summary: "Merge the directory into a parent context",
            detail:
              "Move the files into the parent context that already calls them. The boundary disappears, the " <>
                "code lives next to its closest collaborators, and you stop paying the public-API cost for " <>
                "almost nothing.",
            applies_when: "There is an obvious larger context the files naturally belong to."
          ),
          Fix.new(
            summary: "Grow the context until it has a real surface area",
            detail:
              "If the directory is small because the feature is still being built out, leave it but make sure " <>
                "the rest of the planned scope lands here too. Add a TODO/moduledoc note so reviewers know.",
            applies_when: "The context will grow as the feature is implemented."
          ),
          Fix.new(
            summary: "Inline the modules into their (single) caller",
            detail:
              "If the context is only ever called from one other module, fold the files into that caller. " <>
                "There's no need for a separate boundary when there's only one consumer.",
            applies_when: "Exactly one caller uses the context."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#1.11"],
        context: %{path: dir, file_count: length(files), threshold: threshold},
        file: dir,
        line: 0
      )
    end)
  end

  # §§ elixir-implementing: §10.5 — central config-accessor pattern.
  defp min_files(opts) do
    case Keyword.get(opts, :config) do
      %Config{} = config -> Config.threshold(config, "1.11", :min_files, @min_files)
      _ -> @min_files
    end
  end

  defp context_dir(file) do
    case String.split(file, "/lib/") do
      [_, rest] ->
        parts = String.split(rest, "/")

        case parts do
          [app, context | rest_parts] when rest_parts != [] ->
            "lib/" <> app <> "/" <> context

          _ ->
            nil
        end

      _ ->
        nil
    end
  end
end
