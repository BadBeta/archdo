defmodule Archdo.Rules.Module.HandRolledTokenCrypto do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.94"

  @impl true
  def description,
    do:
      "`:crypto.mac` / `:crypto.hash` / `:crypto.hmac` in an auth/token/session " <>
        "module — likely hand-rolled JWT or password hashing; use Guardian / " <>
        "Joken / bcrypt_elixir / argon2_elixir"

  # Module-name segments that strongly suggest auth/token/session purpose.
  @auth_segments ~w(Auth Token Session JWT Otp Verifier Signer)

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    case auth_module?(ast) do
      false -> []
      true -> ast |> AST.find_all(&crypto_call?/1) |> Enum.map(&diagnose(file, &1))
    end
  end

  defp auth_module?(ast) do
    AST.find_all(ast, fn
      {:defmodule, _, [{:__aliases__, _, parts} | _]} -> module_name_matches?(parts)
      _ -> false
    end)
    |> Enum.any?()
  end

  defp module_name_matches?(parts) when is_list(parts) do
    Enum.any?(parts, fn part ->
      is_atom(part) and Atom.to_string(part) in @auth_segments
    end)
  end

  defp module_name_matches?(_), do: false

  defp crypto_call?({{:., _, [:crypto, fun]}, _, _}) when fun in [:mac, :hmac, :hash],
    do: true

  defp crypto_call?(_), do: false

  defp diagnose(file, {{:., _, [:crypto, fun]}, meta, _}) do
    build_diagnostic(file, AST.line(meta), ":crypto.#{fun}")
  end

  defp build_diagnostic(file, line, call) do
    Diagnostic.warning("6.94",
      title: "`#{call}` in auth/token module — use a vetted library",
      message:
        "An auth-flavored module (Auth / Token / Session / JWT / OTP / Verifier / " <>
          "Signer) calls `#{call}` directly. This pattern is the start of a hand- " <>
          "rolled JWT, signed cookie, or password hash — and that path has " <>
          "consumed entire engineering quarters chasing timing attacks, weak " <>
          "salts, leaked secrets in logs, and version-skew between sign and " <>
          "verify. Use a vetted library: Guardian (JWT for APIs), `phx.gen.auth` " <>
          "(sessions for browser apps), `bcrypt_elixir` / `argon2_elixir` " <>
          "(passwords), `Plug.Crypto.sign/verify` (signed-cookie tokens).",
      why:
        "Security primitives need: constant-time comparisons (a non-constant `==` " <>
          "on a digest is exploitable from a remote network); algorithm pinning " <>
          "(the wrong `:sha256` vs `:sha512` choice or a `none` JWT alg silently " <>
          "destroys the whole signature); KDF parameters that are tuned to the " <>
          "deployment (bcrypt rounds for prod, lower for test); replay protection " <>
          "(`exp`, `nbf`, jti); proper key rotation. A library bakes all of this " <>
          "in. Hand-rolled code accumulates near-misses and only one of them needs " <>
          "to land. The default answer to \"can I just use `:crypto.mac` for " <>
          "this?\" is no.",
      alternatives: [
        Fix.new(
          summary: "JWT / API tokens → Guardian + Joken",
          detail:
            "use Guardian, otp_app: :my_app\n" <>
              "def subject_for_token(%User{id: id}, _claims), do: {:ok, to_string(id)}\n" <>
              "def resource_from_claims(%{\"sub\" => id}), do: Accounts.fetch_user(id)",
          applies_when: "When the token is consumed by external clients (mobile / SPA / API)."
        ),
        Fix.new(
          summary: "Browser sessions → `phx.gen.auth`",
          detail:
            "mix phx.gen.auth Accounts User users\n" <>
              "# Generates: hashed_password column, session token table, " <>
              "session-cookie plug pipeline, registration / login / reset flows.",
          applies_when: "Server-rendered web apps."
        ),
        Fix.new(
          summary: "Password hashing → bcrypt_elixir or argon2_elixir",
          detail:
            "Bcrypt.hash_pwd_salt(password)            # store this\n" <>
              "Bcrypt.verify_pass(input, stored_hash)    # constant-time compare\n" <>
              "# In config/test.exs: config :bcrypt_elixir, log_rounds: 4",
          applies_when: "When you control passwords in your DB."
        ),
        Fix.new(
          summary: "Signed cookies / short-lived tokens → `Plug.Crypto`",
          detail:
            "Plug.Crypto.sign(secret, \"reset-token\", user.id, max_age: 3600)\n" <>
              "Plug.Crypto.verify(secret, \"reset-token\", token, max_age: 3600)",
          applies_when: "Reset tokens, email-confirmation tokens, signed parameters."
        )
      ],
      references: [
        "elixir-implementing/SKILL.md#1",
        "elixir-implementing/SKILL.md#8.2.1",
        "elixir-reviewing/security-audit-deep.md"
      ],
      context: %{call: call},
      file: file,
      line: line
    )
  end
end
