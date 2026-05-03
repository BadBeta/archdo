defmodule Archdo.Rules.Module.ModuleLength do
  @moduledoc false
  @behaviour Archdo.Rule

  # Reading the source file to count lines IS the responsibility.
  Module.register_attribute(__MODULE__, :archdo_volatility, persist: true)
  @archdo_volatility :stable

  alias Archdo.{AST, Diagnostic, Fix}

  @warn_lines 500
  @error_lines 1000

  @impl true
  def id, do: "6.4"

  @impl true
  def description, do: "Module length as architecture signal — long files do too much"

  @impl true
  def analyze(file, _ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      case File.read(file) do
        {:ok, content} ->
          lines =
            content
            |> String.split("\n")
            |> length()

          check_length(file, lines)

        _ ->
          []
      end
    end
  end

  defp check_length(file, lines) do
    cond do
      lines > @error_lines ->
        [length_diag(file, lines, :warning)]

      lines > @warn_lines ->
        [length_diag(file, lines, :info)]

      true ->
        []
    end
  end

  defp length_diag(file, lines, severity) do
    builder = Diagnostic.builder_for(severity)

    builder.("6.4",
      title: "Module file too long",
      message: "File has #{lines} lines (warn at #{@warn_lines}, error at #{@error_lines})",
      why:
        "Long files almost always hide multiple responsibilities. Above ~500 lines navigation gets harder, " <>
          "git diffs become noisy, and the file starts pulling in dependencies that only some of its " <>
          "functions use. The line count is a leading indicator of cohesion problems.",
      alternatives: [
        Fix.new(
          summary: "Extract sub-modules along the natural seams",
          detail:
            "Look for clusters of functions that share helpers, prefixes, or aliases — those are usually a " <>
              "sub-module trying to escape. Pull each cluster into its own file under the same namespace.",
          applies_when: "The file contains multiple responsibilities."
        ),
        Fix.new(
          summary: "Accept the length if the file is genuinely cohesive",
          detail:
            "Some files (a complex parser, a code generator) are genuinely one large unit. If the file is " <>
              "internally coherent and splitting would create artificial boundaries, add to the freeze baseline.",
          applies_when: "The file is coherent despite its size."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.4"],
      context: %{lines: lines, threshold_warn: @warn_lines, threshold_error: @error_lines},
      file: file,
      line: 1
    )
  end
end
