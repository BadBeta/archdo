defmodule Archdo.Rules.Testing.HardcodedTestData do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "7.20"

  @impl true
  def description, do: "Test uses hardcoded real-looking emails, URLs, or API keys"

  @impl true
  def analyze(file, _ast, _opts) do
    case AST.test_file?(file) do
      false -> []
      true -> check_hardcoded_data(file)
    end
  end

  defp suspicious_patterns do
    [
      ~r/\b[a-zA-Z0-9._%+-]+@(gmail|yahoo|hotmail|outlook)\.(com|org|net)\b/,
      ~r/sk_(test|live)_[a-zA-Z0-9]{20,}/,
      ~r/pk_(test|live)_[a-zA-Z0-9]{20,}/,
      ~r/Bearer\s+[a-zA-Z0-9._-]{20,}/
    ]
  end

  defp check_hardcoded_data(file) do
    case File.read(file) do
      {:ok, content} ->
        findings =
          suspicious_patterns()
          |> Enum.flat_map(fn pattern ->
            case Regex.run(pattern, content) do
              [match | _] -> [match]
              _ -> []
            end
          end)
          |> Enum.take(3)

        case findings do
          [] ->
            []

          [match | _] ->
            [
              Diagnostic.info("7.20",
                title: "Hardcoded test data",
                message: "Test file contains real-looking data: #{String.slice(match, 0, 40)}",
                why:
                  "Hardcoded real email addresses, API keys, or production URLs in tests risk " <>
                    "accidental side effects (sending real emails, hitting real APIs) and make " <>
                    "tests brittle. Use factories, faker libraries, or @example.com domains.",
                alternatives: [
                  Fix.new(
                    summary: "Use @example.com for email addresses",
                    detail: "RFC 2606 reserves example.com for testing. Use `user@example.com`.",
                    applies_when: "Tests need email addresses."
                  ),
                  Fix.new(
                    summary: "Use factories or fixtures for test data",
                    detail: "Generate unique test data with ExMachina, Faker, or custom fixtures.",
                    applies_when: "Tests need realistic but non-production data."
                  )
                ],
                references: ["ARCHITECTURE_RULES.md#7.20"],
                context: %{sample: String.slice(match, 0, 40)},
                file: file,
                line: 1
              )
            ]
        end

      {:error, _} ->
        []
    end
  end
end
