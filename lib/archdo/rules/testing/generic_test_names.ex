defmodule Archdo.Rules.Testing.GenericTestNames do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "7.17"

  @impl true
  def description, do: "Test names should be descriptive — not 'it works', 'test 1', etc."

  # Exact-match generic names (case-insensitive)
  @generic_exact ~w(test ok works basic simple foo bar todo wip example)

  # Prefix matches for "test 1", "test 2", "test_3", etc
  @generic_prefixes ~w(test_ case_ example_)

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      false -> []
      true -> find_generic_names(file, ast)
    end
  end

  defp find_generic_names(file, ast) do
    ast
    |> AST.find_all(fn
      {:test, _, [_name | _]} -> true
      _ -> false
    end)
    |> Enum.flat_map(fn {:test, meta, args} ->
      name = extract_name(args)

      cond do
        is_nil(name) -> []
        generic?(name) -> [build_diagnostic(file, meta, name)]
        too_short?(name) -> [build_diagnostic(file, meta, name)]
        true -> []
      end
    end)
  end

  defp extract_name([name | _]) when is_binary(name), do: name
  defp extract_name([{:__block__, _, [name]} | _]) when is_binary(name), do: name
  defp extract_name(_), do: nil

  defp generic?(name) do
    lower = String.downcase(String.trim(name))

    # Pure numeric like "1", "2", "3"
    lower in @generic_exact or
      lower == "it works" or
      Enum.any?(@generic_prefixes, fn prefix ->
        String.starts_with?(lower, prefix) and
          remainder_is_numeric?(String.replace_prefix(lower, prefix, ""))
      end) or
      String.match?(lower, ~r/^\d+$/)
  end

  defp remainder_is_numeric?(""), do: true
  defp remainder_is_numeric?(rest), do: String.match?(rest, ~r/^\d+$/)

  # Less than 3 words and less than 15 characters is probably too generic
  defp too_short?(name) do
    word_count = name |> String.split(~r/\s+/, trim: true) |> length()
    String.length(name) < 10 and word_count < 2
  end

  defp build_diagnostic(file, meta, name) do
    Diagnostic.info("7.17",
      title: "Generic test name",
      message: "Test name `\"#{name}\"` describes nothing about the behaviour being verified",
      why:
        "Test names are documentation that's read by everyone who runs the suite. `test \"works\"` or " <>
          "`test \"test 1\"` tells the reader nothing about what the test verifies, what's expected to happen, " <>
          "or what broke when it fails. The test failure message becomes useless without reading the body.",
      alternatives: [
        Fix.new(
          summary: "Rename the test to describe the expected behaviour",
          detail:
            "Use the pattern `\"<verb> <object> when <condition>\"` — e.g. " <>
              "`\"returns {:error, :not_found} when user doesn't exist\"`. The name reads as a sentence, the " <>
              "failure message becomes self-explanatory, and the test acts as documentation of the contract.",
          applies_when: "The test is meaningful."
        ),
        Fix.new(
          summary: "Delete the test if it's a placeholder",
          detail:
            ~s(If the test is named `"todo"` or `"foo"` because it was scaffolded and never finished, delete it.),
          applies_when: "The test is unfinished scaffolding."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#7.17"],
      context: %{name: name},
      file: file,
      line: AST.line(meta)
    )
  end
end
