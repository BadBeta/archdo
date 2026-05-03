defmodule Archdo.Rules.Module.SecretStructInspect do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.54"

  @impl true
  def description,
    do: "Struct with secret-bearing field but no Inspect protection — leaks via crash dumps"

  # §§ elixir-implementing: §1 #23 SSOT — closed allowlist instead of substring
  # match. Substring `String.contains?(name, "token")` false-positives on
  # `token_count`, `password_policy`, etc. Each entry here is a deliberately-
  # listed sensitive field name.
  @sensitive_fields [
    :token,
    :auth_token,
    :access_token,
    :refresh_token,
    :session_token,
    :reset_token,
    :bearer_token,
    :csrf_token,
    :id_token,
    :secret,
    :client_secret,
    :secret_key,
    :secret_key_base,
    :api_key,
    :api_secret,
    :private_key,
    :signing_key,
    :encryption_key,
    :password,
    :password_hash,
    :password_digest,
    :hashed_password,
    :encrypted_password,
    :otp_secret,
    :totp_secret
  ]

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_unprotected_structs(file, ast)
    end
  end

  defp find_unprotected_structs(file, ast) do
    structs = collect_struct_modules(ast)

    Enum.flat_map(structs, fn {meta, fields, derives, has_inspect_impl?} ->
      classify(file, meta, fields, derives, has_inspect_impl?)
    end)
  end

  defp classify(file, meta, fields, derives, has_inspect_impl?) do
    sensitive = sensitive_fields_present(fields)

    case {sensitive, inspect_protected?(derives, has_inspect_impl?)} do
      {[], _} -> []
      {_, true} -> []
      {hits, false} -> [build_diagnostic(file, meta, hits)]
    end
  end

  defp sensitive_fields_present(fields) do
    Enum.filter(fields, &(&1 in @sensitive_fields))
  end

  # Walk every defmodule, collecting:
  #   - defstruct line + field-name list
  #   - @derive specs in that module
  #   - whether a `defimpl Inspect, for: __MODULE__` exists in that module
  defp collect_struct_modules(ast) do
    {_, structs} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [_alias, [do: body]]} = node, acc ->
          case extract_struct_info(body) do
            nil -> {node, acc}
            info -> {node, [info | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    structs
  end

  defp extract_struct_info(body) do
    body_list = unwrap_block(body)

    case Enum.find(body_list, &defstruct?/1) do
      nil ->
        nil

      defstruct_node ->
        {meta, fields} = read_defstruct(defstruct_node)
        derives = collect_derives_in(body_list)
        has_inspect_impl? = Enum.any?(body_list, &inspect_defimpl?/1)
        {meta, fields, derives, has_inspect_impl?}
    end
  end

  defp unwrap_block({:__block__, _, items}) when is_list(items), do: items
  defp unwrap_block(single), do: [single]

  defp defstruct?({:defstruct, _, [_]}), do: true
  defp defstruct?(_), do: false

  defp read_defstruct({:defstruct, meta, [fields]}) when is_list(fields) do
    names =
      Enum.map(fields, fn
        {name, _default} -> name
        name when is_atom(name) -> name
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    {meta, names}
  end

  defp read_defstruct({:defstruct, meta, _other}), do: {meta, []}

  defp collect_derives_in(body_list) do
    Enum.flat_map(body_list, fn
      {:@, _, [{:derive, _, [spec]}]} -> [spec]
      _ -> []
    end)
  end

  defp inspect_defimpl?({:defimpl, _, [{:__aliases__, _, [:Inspect]} | _]}), do: true
  defp inspect_defimpl?(_), do: false

  # §§ elixir-implementing: §5.2, §7.6 — multi-clause head dispatch over the
  # @derive shape variants. `@derive {Inspect, only: [...]}`,
  # `@derive {Inspect, except: [...]}`, or bare `@derive Inspect` all
  # constitute protection (the bare form just inherits the default — but if
  # the user explicitly derived, we trust the intent).
  defp inspect_protected?(_derives, true), do: true
  defp inspect_protected?(derives, false), do: Enum.any?(derives, &inspect_derive?/1)

  defp inspect_derive?({:__aliases__, _, [:Inspect]}), do: true
  defp inspect_derive?({{:__aliases__, _, [:Inspect]}, _opts}), do: true
  defp inspect_derive?({:{}, _, [{:__aliases__, _, [:Inspect]} | _]}), do: true
  defp inspect_derive?(_), do: false

  defp build_diagnostic(file, meta, hits) do
    names = Enum.map_join(hits, ", ", &Atom.to_string/1)

    Diagnostic.warning("5.54",
      title: "Struct with secret-bearing field has no Inspect protection",
      message:
        "Struct fields #{names} look like secrets, but the module has no " <>
          "`@derive {Inspect, only: [...]}` and no `defimpl Inspect`. Crash " <>
          "reports, IO.inspect, and observer will print these fields verbatim.",
      why:
        "When a process crashes, the BEAM includes the process state in the " <>
          "crash report — visible in logs, observer, and remote shells. Without " <>
          "an Inspect override, every struct field (including tokens, passwords, " <>
          "and keys) is printed. Production crash dumps end up in monitoring " <>
          "systems and are sometimes shared in incident channels.",
      alternatives: [
        Fix.new(
          summary: "Add @derive {Inspect, only: [...]} naming the safe fields",
          detail:
            "Place `@derive {Inspect, only: [:id, :user_id, :inserted_at]}` " <>
              "immediately before `defstruct`. Sensitive fields will then render " <>
              "as `#Struct<...>` in inspect output.",
          applies_when: "The set of safe-to-inspect fields is small and stable."
        ),
        Fix.new(
          summary: "Add @derive {Inspect, except: [:token, :password]}",
          detail:
            "When most fields are safe and only a few are sensitive, list the " <>
              "sensitive ones in `:except` rather than maintaining the inverse list.",
          applies_when: "Most fields are safe to inspect; only a few must be hidden."
        ),
        Fix.new(
          summary: "Implement defimpl Inspect for full custom rendering",
          detail:
            "When the inspect output should look domain-specific " <>
              "(e.g. `#Session<user=42>`) rather than struct-shaped, define " <>
              "`defimpl Inspect, for: __MODULE__ do def inspect(s, opts), do: ... end`.",
          applies_when: "You want non-default inspect output that hides everything sensitive."
        )
      ],
      tags: [:security, :high],
      file: file,
      line: AST.line(meta)
    )
  end
end
