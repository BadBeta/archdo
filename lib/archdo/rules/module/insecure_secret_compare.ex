defmodule Archdo.Rules.Module.InsecureSecretCompare do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.79"

  @impl true
  def description,
    do:
      "`==` comparison where one side has a secret-suggesting name — " <>
        "use Plug.Crypto.secure_compare/2 (constant-time)"

  # Variable-name substrings that suggest a secret. Heuristic; matches
  # against the variable name (atom) of either side of `==`.
  @secret_keywords [
    "token",
    "hmac",
    "digest",
    "signature",
    "api_key",
    "apikey",
    "secret",
    "session_id",
    "csrf",
    "password_hash"
  ]

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    Enum.map(AST.find_all(ast, &secret_compare?/1), fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta))
    end)
  end

  # `==` (or `===`) at the boolean / return level where one side
  # references a variable whose name suggests a secret. AST shape:
  # `{:==, _, [lhs, rhs]}` or `{:===, _, [lhs, rhs]}`.
  defp secret_compare?({op, _, [a, b]}) when op in [:==, :===] do
    secret_var?(a) or secret_var?(b)
  end

  defp secret_compare?(_), do: false

  defp secret_var?({name, _, ctx}) when is_atom(name) and is_atom(ctx) do
    name_str = name |> Atom.to_string() |> String.downcase()
    Enum.any?(@secret_keywords, &String.contains?(name_str, &1))
  end

  defp secret_var?(_), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.warning("6.79",
      title: "Variable-time comparison of a secret — use constant-time compare",
      message:
        "This `==` comparison's variable name suggests a secret (token / hmac / digest / " <>
          "signature / api_key / etc.). The default `==` operator is variable-time: it " <>
          "short-circuits on the first mismatched byte, leaking timing information that " <>
          "can be exploited remotely. Use `Plug.Crypto.secure_compare/2`.",
      why:
        "Constant-time secret comparison is a textbook security primitive. The attack: an " <>
          "attacker submits guessed secrets and measures response time; the prefix that " <>
          "matches gets revealed by the longer comparison time. `Plug.Crypto.secure_compare/2` " <>
          "always runs in time proportional to the LONGER of the two strings, regardless of " <>
          "where the first mismatch occurs.",
      alternatives: [
        Fix.new(
          summary: "Use Plug.Crypto.secure_compare/2",
          detail:
            "Plug.Crypto.secure_compare(submitted_token, expected_token)\n" <>
              "# returns true iff the strings match, in constant time",
          applies_when: "Always for any value that came from an untrusted source."
        ),
        Fix.new(
          summary: "For passwords specifically, use the password lib's verifier",
          detail:
            "Bcrypt.verify_pass(input, hash)  # bcrypt_elixir\n" <>
              "Argon2.verify_pass(input, hash) # argon2_elixir\n" <>
              "These are already constant-time and use the right comparison strategy.",
          applies_when: "When the comparison is for password verification."
        )
      ],
      references: ["elixir-implementing/SKILL.md#8.2.1"],
      context: %{},
      file: file,
      line: line
    )
  end
end
