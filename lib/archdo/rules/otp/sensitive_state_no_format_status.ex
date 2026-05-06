defmodule Archdo.Rules.OTP.SensitiveStateNoFormatStatus do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.63"

  @impl true
  def description,
    do:
      "GenServer with sensitive-named state fields (token / password / secret / api_key / " <>
        "etc.) and no `format_status/1,2` callback — crashes / sys.get_state expose secrets"

  @sensitive_keywords [
    "password",
    "token",
    "secret",
    "api_key",
    "apikey",
    "private_key",
    "session_id",
    "auth",
    "hmac",
    "credential"
  ]

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    case AST.genserver_module?(ast) do
      false -> []
      true -> check_state_and_format_status(file, ast)
    end
  end

  defp check_state_and_format_status(file, ast) do
    case sensitive_state_fields(ast) do
      [] ->
        []

      fields ->
        case has_format_status?(ast) do
          true -> []
          false -> [build_diagnostic(file, defstruct_line(ast), fields)]
        end
    end
  end

  # Find `defstruct [:field, :field, ...]` and return the fields whose
  # name matches a sensitive keyword.
  defp sensitive_state_fields(ast) do
    {_, fields} =
      Macro.prewalk(ast, [], fn
        {:defstruct, _, [field_list]} = node, acc when is_list(field_list) ->
          {node, sensitive_in_field_list(field_list) ++ acc}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(fields)
  end

  defp sensitive_in_field_list(fields) do
    Enum.flat_map(fields, fn
      atom when is_atom(atom) ->
        case sensitive_atom?(atom),
          do: (
            true -> [atom]
            false -> []
          )

      {atom, _default} when is_atom(atom) ->
        case sensitive_atom?(atom),
          do: (
            true -> [atom]
            false -> []
          )

      _ ->
        []
    end)
  end

  defp sensitive_atom?(atom) do
    name_str = atom |> Atom.to_string() |> String.downcase()
    Enum.any?(@sensitive_keywords, &String.contains?(name_str, &1))
  end

  defp has_format_status?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {:def, _, [{:format_status, _, args} | _]} = node, _acc when is_list(args) ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp defstruct_line(ast) do
    {_, line} =
      Macro.prewalk(ast, 1, fn
        {:defstruct, meta, _} = node, _acc -> {node, AST.line(meta)}
        node, acc -> {node, acc}
      end)

    line
  end

  defp build_diagnostic(file, line, fields) do
    field_list = Enum.map_join(fields, ", ", &":#{&1}")

    Diagnostic.warning("5.63",
      title: "GenServer with sensitive state and no `format_status/1,2`",
      message:
        "This GenServer's state struct has sensitive-named fields (#{field_list}) but " <>
          "defines no `format_status/1,2` callback. Crash logs, `:sys.get_state/1`, and " <>
          "`Process.info/2` will expose those values verbatim.",
      why:
        "When a GenServer crashes, OTP logs the FULL state. Tools like `:sys.get_state/1` " <>
          "and `:observer` show the state on demand. Without `format_status/1,2`, secrets " <>
          "in the state struct end up in production logs and operator-debug sessions. " <>
          "The callback lets you redact specific fields before they're displayed.",
      alternatives: [
        Fix.new(
          summary: "Implement format_status/2 to redact sensitive fields",
          detail: """
          @impl true
          def format_status(_reason, [_pdict, state]) do
            [data: [{~c"State", %{state | api_key: "[REDACTED]"}}]]
          end
          """,
          applies_when: "Always when state contains tokens / passwords / api_keys / etc."
        ),
        Fix.new(
          summary: "Or move secrets out of GenServer state entirely",
          detail:
            "Keep secrets in `:persistent_term` or fetch from a secrets manager on demand. " <>
              "GenServer state then only holds opaque references / handles.",
          applies_when: "When the secret can be fetched per-call or doesn't change at runtime."
        )
      ],
      references: ["elixir-implementing/SKILL.md#9.6"],
      context: %{fields: fields},
      file: file,
      line: line
    )
  end
end
