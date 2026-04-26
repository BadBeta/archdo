defmodule Archdo.Rules.Module.SensitiveDataExposure do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.56"

  @impl true
  def description, do: "Sensitive data may be exposed through logs, encoders, or error messages"

  # Field names that indicate sensitive data
  @sensitive_fields [
    :password,
    :password_hash,
    :password_digest,
    :hashed_password,
    :encrypted_password,
    :secret,
    :secret_key,
    :secret_key_base,
    :api_key,
    :api_secret,
    :token,
    :auth_token,
    :access_token,
    :refresh_token,
    :session_token,
    :reset_token,
    :private_key,
    :signing_key,
    :encryption_key,
    :credit_card,
    :card_number,
    :cvv,
    :ssn,
    :social_security,
    :otp_secret,
    :totp_secret,
    :recovery_codes
  ]

  # String patterns that indicate hardcoded secrets
  @secret_prefixes [
    "sk_live_",
    "sk_test_",
    "pk_live_",
    "pk_test_",
    "ghp_",
    "gho_",
    "github_pat_",
    "xoxb-",
    "xoxp-",
    "xapp-",
    "AKIA",
    "eyJ"
  ]

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_exposure(file, ast)
    end
  end

  defp find_exposure(file, ast) do
    List.flatten([
      find_missing_inspect_derive(file, ast),
      find_overbroad_jason_encoder(file, ast),
      find_inspect_on_sensitive_struct(file, ast),
      find_sensitive_in_logger(file, ast),
      find_hardcoded_secrets(file, ast),
      find_sensitive_in_error_message(file, ast)
    ])
  end

  # ================================================================
  # 1. Struct with sensitive fields but no @derive {Inspect, only: [...]}
  # ================================================================

  defp find_missing_inspect_derive(file, ast) do
    structs = find_struct_definitions(ast)

    Enum.flat_map(structs, fn {meta, fields, derives} ->
      sensitive = Enum.filter(fields, &sensitive_field?/1)

      case {sensitive, has_inspect_derive?(derives)} do
        {[_ | _], false} ->
          names = Enum.map_join(sensitive, ", ", &Atom.to_string/1)

          [
            Diagnostic.info("6.56",
              title: "Struct with sensitive fields lacks @derive Inspect",
              message:
                "Struct has sensitive fields (#{names}) but no " <>
                  "`@derive {Inspect, only: [...]}` — crash reports and IO.inspect will expose them",
              why:
                "When a process crashes, the BEAM includes the process state in the crash report. " <>
                  "Without an Inspect derive, all struct fields — including passwords, tokens, and keys — " <>
                  "are visible in logs, observer, and remote shell output.",
              alternatives: [
                Fix.new(
                  summary: "Add @derive {Inspect, only: [...]} before defstruct",
                  detail:
                    "List only the safe fields: " <>
                      "`@derive {Inspect, only: [:id, :email, :name]}` — " <>
                      "sensitive fields will show as `#MyStruct<...>`.",
                  applies_when: "The struct contains any sensitive field."
                )
              ],
              tags: [],
              file: file,
              line: AST.line(meta)
            )
          ]

        _ ->
          []
      end
    end)
  end

  # ================================================================
  # 2. @derive Jason.Encoder without :only on a struct with sensitive fields
  # ================================================================

  defp find_overbroad_jason_encoder(file, ast) do
    structs = find_struct_definitions(ast)

    Enum.flat_map(structs, fn {meta, fields, derives} ->
      sensitive = Enum.filter(fields, &sensitive_field?/1)

      case {sensitive, has_overbroad_jason_derive?(derives)} do
        {[_ | _], true} ->
          names = Enum.map_join(sensitive, ", ", &Atom.to_string/1)

          [
            Diagnostic.warning("6.56",
              title: "Jason.Encoder derives all fields including sensitive ones",
              message: "`@derive Jason.Encoder` encodes ALL fields — including #{names}",
              why:
                "Without an `:only` or `:except` option, Jason.Encoder serializes every field " <>
                  "in the struct. If this struct is returned in an API response or logged as JSON, " <>
                  "sensitive fields like passwords and tokens will be included.",
              alternatives: [
                Fix.new(
                  summary: "Use @derive {Jason.Encoder, only: [...]}",
                  detail:
                    "Explicitly list the safe fields: " <>
                      "`@derive {Jason.Encoder, only: [:id, :email, :name]}`",
                  applies_when: "The struct is serialized to JSON."
                )
              ],
              tags: [],
              file: file,
              line: AST.line(meta)
            )
          ]

        _ ->
          []
      end
    end)
  end

  # ================================================================
  # 3. IO.inspect / inspect() called on a variable with a sensitive name
  # ================================================================

  defp find_inspect_on_sensitive_struct(file, ast) do
    Enum.map(
      AST.find_all(ast, fn
        # IO.inspect(user) where user might contain sensitive data
        {{:., _, [{:__aliases__, _, [:IO]}, :inspect]}, _, [{var, _, ctx} | _]}
        when is_atom(var) and is_atom(ctx) ->
          sensitive_variable_name?(var)

        # Logger.info("... #{inspect(user)}")
        # This is harder to detect precisely; check for inspect() calls on sensitive vars
        {:inspect, _, [{var, _, ctx} | _]} when is_atom(var) and is_atom(ctx) ->
          sensitive_variable_name?(var)

        _ ->
          false
      end),
      fn {_, meta, _} ->
        Diagnostic.info("6.56",
          title: "inspect() on potentially sensitive variable",
          message:
            "Calling inspect on a variable that may contain sensitive data — " <>
              "use @derive {Inspect, only: [...]} on the struct to redact fields",
          why:
            "IO.inspect and inspect() output ALL fields of a struct by default. " <>
              "If the struct contains passwords, tokens, or keys, they'll appear in logs.",
          alternatives: [
            Fix.new(
              summary: "Add @derive Inspect to the struct, or inspect specific fields",
              detail:
                "Use `IO.inspect(var, only: [:id, :email])` or ensure the struct has " <>
                  "`@derive {Inspect, only: [...]}` excluding sensitive fields.",
              applies_when: "The variable holds a struct with sensitive fields."
            )
          ],
          tags: [],
          file: file,
          line: AST.line(meta)
        )
      end
    )
  end

  # ================================================================
  # 4. Logger calls with interpolated sensitive variables
  # ================================================================

  defp find_sensitive_in_logger(file, ast) do
    Enum.map(
      AST.find_all(ast, fn
        # Logger.info("User: #{inspect(credentials)}")
        {{:., _, [{:__aliases__, _, [:Logger]}, level]}, _, [msg | _]}
        when level in [:debug, :info, :notice, :warning, :error] ->
          contains_sensitive_interpolation?(msg)

        _ ->
          false
      end),
      fn {_, meta, _} ->
        Diagnostic.info("6.56",
          title: "Logger call may expose sensitive data",
          message: "Logger message interpolates a variable with a sensitive name",
          why:
            "Log messages are often stored in centralized logging systems accessible to " <>
              "operations teams. Sensitive data in logs violates the principle of least exposure " <>
              "and may breach compliance requirements (GDPR, PCI-DSS, SOC2).",
          alternatives: [
            Fix.new(
              summary: "Log only non-sensitive identifiers",
              detail:
                "Instead of `Logger.info(\"User: \#{inspect(user)}\")`, " <>
                  "use `Logger.info(\"User action\", user_id: user.id)`.",
              applies_when: "The log message contains user data, credentials, or tokens."
            )
          ],
          tags: [],
          file: file,
          line: AST.line(meta)
        )
      end
    )
  end

  # ================================================================
  # 5. Hardcoded secrets in module attributes or function bodies
  # ================================================================

  defp find_hardcoded_secrets(file, ast) do
    # Check module attributes with sensitive names
    attr_hits =
      Enum.map(
        AST.find_all(ast, fn
          {:@, _, [{name, _, [value]}]}
          when is_atom(name) and is_binary(value) ->
            sensitive_attr_name?(name) and String.length(value) > 8

          {:@, _, [{name, _, [{:__block__, _, [value]}]}]}
          when is_atom(name) and is_binary(value) ->
            sensitive_attr_name?(name) and String.length(value) > 8

          _ ->
            false
        end),
        fn {_, meta, _} ->
          build_secret_diagnostic(file, AST.line(meta))
        end
      )

    # Check string literals that look like known API key formats.
    # Must be longer than the prefix itself (prefix alone is a pattern, not a secret).
    prefix_hits =
      Enum.map(
        AST.find_all(ast, fn
          {:__block__, _, [value]} when is_binary(value) and byte_size(value) > 12 ->
            Enum.any?(@secret_prefixes, &String.starts_with?(value, &1))

          _ ->
            false
        end),
        fn {_, meta, _} ->
          build_secret_diagnostic(file, AST.line(meta))
        end
      )

    attr_hits ++ prefix_hits
  end

  defp build_secret_diagnostic(file, line) do
    Diagnostic.warning("6.56",
      title: "Possible hardcoded secret",
      message: "A string that looks like a secret or API key is hardcoded in source code",
      why:
        "Hardcoded secrets are visible in version control, build artifacts, and crash dumps. " <>
          "Use environment variables (System.fetch_env!/1 in runtime.exs) or a secrets manager.",
      alternatives: [
        Fix.new(
          summary: "Move to environment variable or secrets manager",
          detail:
            "Store in `config/runtime.exs`: `config :my_app, :api_key, System.fetch_env!(\"API_KEY\")`",
          applies_when: "The value is a real secret, not a test fixture."
        )
      ],
      tags: [],
      file: file,
      line: line
    )
  end

  # ================================================================
  # 6. Sensitive data in raise/error messages
  # ================================================================

  defp find_sensitive_in_error_message(file, ast) do
    Enum.map(
      AST.find_all(ast, fn
        # raise "Failed: #{inspect(credentials)}"
        {:raise, _, [msg | _]} ->
          contains_sensitive_interpolation?(msg)

        _ ->
          false
      end),
      fn {_, meta, _} ->
        Diagnostic.info("6.56",
          title: "Error message may expose sensitive data",
          message: "raise/error message interpolates a potentially sensitive variable",
          why:
            "Exception messages appear in logs, error tracking services (Sentry, Honeybadger), " <>
              "and sometimes in HTTP responses. Sensitive data in error messages can leak to " <>
              "unauthorized parties.",
          alternatives: [
            Fix.new(
              summary: "Log sensitive context separately, raise with safe message",
              detail:
                "Use `Logger.error(\"auth failed\", user_id: id)` for context, " <>
                  "then `raise \"Authentication failed\"` with a generic message.",
              applies_when: "The error message contains user data or credentials."
            )
          ],
          tags: [],
          file: file,
          line: AST.line(meta)
        )
      end
    )
  end

  # ================================================================
  # Helpers
  # ================================================================

  defp find_struct_definitions(ast) do
    {_, structs} =
      Macro.prewalk(ast, [], fn
        {:defstruct, meta, [fields]} = node, acc when is_list(fields) ->
          field_names =
            Enum.map(fields, fn
              {name, _default} -> name
              name when is_atom(name) -> name
              _ -> nil
            end)

          derives = collect_derives(ast, AST.line(meta))
          {node, [{meta, Enum.reject(field_names, &is_nil/1), derives} | acc]}

        {:defstruct, meta, [[{_, _} | _] = fields]} = node, acc ->
          field_names = Enum.map(fields, fn {name, _} -> name end)
          derives = collect_derives(ast, AST.line(meta))
          {node, [{meta, field_names, derives} | acc]}

        node, acc ->
          {node, acc}
      end)

    structs
  end

  defp collect_derives(ast, _struct_line) do
    {_, derives} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{:derive, _, [derive_spec]}]} = node, acc ->
          {node, [derive_spec | acc]}

        node, acc ->
          {node, acc}
      end)

    derives
  end

  defp has_inspect_derive?(derives) do
    Enum.any?(derives, fn
      {:__aliases__, _, [:Inspect]} -> true
      {:{}, _, [{:__aliases__, _, [:Inspect]} | _]} -> true
      {_, [{:__aliases__, _, [:Inspect]} | _]} -> true
      {{:__aliases__, _, [:Inspect]}, _opts} -> true
      _ -> false
    end)
  end

  defp has_overbroad_jason_derive?(derives) do
    Enum.any?(derives, fn
      # @derive Jason.Encoder — no :only option
      {:__aliases__, _, [:Jason, :Encoder]} ->
        true

      {:__aliases__, _, [_, :Encoder]} ->
        true

      _ ->
        false
    end)
  end

  defp sensitive_field?(field) when is_atom(field) do
    field in @sensitive_fields or
      String.contains?(Atom.to_string(field), [
        "password",
        "secret",
        "token",
        "api_key",
        "private_key"
      ])
  end

  defp sensitive_field?(_), do: false

  defp sensitive_attr_name?(name) do
    name_str = Atom.to_string(name)

    Enum.any?(
      ["secret", "password", "api_key", "token", "private_key", "signing_key"],
      &String.contains?(name_str, &1)
    )
  end

  defp sensitive_variable_name?(var) do
    name = Atom.to_string(var)

    Enum.any?(
      ["password", "secret", "credential", "token", "api_key", "private_key"],
      &String.contains?(name, &1)
    )
  end

  defp contains_sensitive_interpolation?(ast) do
    AST.contains?(ast, fn
      # inspect(credentials) or IO.inspect(credentials)
      {:inspect, _, [{var, _, ctx} | _]} when is_atom(var) and is_atom(ctx) ->
        sensitive_variable_name?(var)

      {{:., _, [{:__aliases__, _, [:IO]}, :inspect]}, _, [{var, _, ctx} | _]}
      when is_atom(var) and is_atom(ctx) ->
        sensitive_variable_name?(var)

      _ ->
        false
    end)
  end
end
