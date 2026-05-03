defmodule Archdo.Rules.Boundary.GodContext do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{Diagnostic, Fix}

  @warn_files 20
  @error_files 40

  @impl true
  def id, do: "4.7"

  @impl true
  def description, do: "Context with too many sub-modules — likely doing too much"

  @doc """
  Project-level: count files under each top-level context directory.
  """
  def analyze_project(source_files) do
    source_files
    |> Enum.group_by(&context_dir/1)
    |> Enum.reject(fn {dir, _} -> is_nil(dir) end)
    |> Enum.flat_map(fn {dir, files} ->
      check_count(dir, length(files))
    end)
  end

  # Returns the context directory: "lib/my_app/accounts"
  defp context_dir(file) do
    case String.split(file, "/lib/") do
      [_, rest] ->
        parts = String.split(rest, "/")

        case parts do
          [app, context | _rest] when context != "" ->
            "lib/" <> app <> "/" <> context

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp check_count(dir, count) do
    cond do
      count > @error_files ->
        [god_context_diag(dir, count, :god)]

      count > @warn_files ->
        [god_context_diag(dir, count, :large)]

      true ->
        []
    end
  end

  defp god_context_diag(dir, count, kind) do
    Diagnostic.info("4.7",
      title: if(kind == :god, do: "God context", else: "Large context"),
      message: "#{dir} contains #{count} files",
      why:
        "Contexts above ~20 files become hard to navigate, slow CI feedback for small changes, and almost " <>
          "always contain multiple distinct responsibilities that have grown together. The boundary stops " <>
          "being meaningful — touching one feature drags in unrelated context modules. The result is the " <>
          "opposite of bounded contexts: a wide, undifferentiated soup.",
      alternatives: [
        Fix.new(
          summary: "Split by feature into sibling contexts",
          detail:
            "Group related files by the user-facing capability they implement (e.g., Cog.Commands.Pipeline, " <>
              "Cog.Commands.Auth). Each new context should be self-contained — its own public API, its own " <>
              "internal modules. The original directory disappears.",
          applies_when: "The files cluster into 3-6 distinct features."
        ),
        Fix.new(
          summary: "Extract leaf submodules without changing the boundary",
          detail:
            "If files are tightly coupled but the count comes from genuine complexity (not unrelated concerns), " <>
              "keep the context but move helpers into Cog.Commands.Pipeline.* sub-namespaces. Reduces directory " <>
              "clutter without creating new boundary contracts.",
          applies_when: "Files share the same domain but have grown organically."
        ),
        Fix.new(
          summary: "Accept the size and document the boundary",
          detail:
            "If the context is genuinely cohesive and active development is winding down, document the " <>
              "responsibility in a moduledoc on the public API module and add to the freeze baseline.",
          applies_when:
            "Splitting would create artificial boundaries with high inter-context coupling."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#4.7"],
      context: %{path: dir, file_count: count, threshold: @warn_files, severity_kind: kind},
      file: dir,
      line: 0
    )
  end
end
