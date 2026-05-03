defmodule Archdo.Rules.Boundary.InternalStructAsEncoder do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "1.22"

  @impl true
  def description,
    do: "Internal struct uses bare @derive Jason.Encoder — fields silently become public API"

  @impl true
  def cleanup_pass, do: 10

  @impl true
  def analyze(file, ast, _opts) do
    case in_scope?(file) do
      true -> find_overbroad_encoder(file, ast)
      false -> []
    end
  end

  # §§ elixir-planning: §6.5 — boundary scope. The rule fires only on
  # internal context modules (`lib/my_app/orders/order.ex`), not on:
  #   - top-level context modules (`lib/my_app/orders.ex`) — these CAN be
  #     intentional public DTO shapes
  #   - *_dto.ex / *_request.ex / *_response.ex / *_event.ex — files named
  #     for the explicit purpose of being on-the-wire
  #   - Phoenix view / json / serializer modules
  #   - Test files
  defp in_scope?(file) do
    not AST.test_file?(file) and
      internal_context_module?(file) and
      not explicit_dto_module?(file) and
      not view_module?(file)
  end

  defp internal_context_module?(file) do
    case Path.split(file) do
      ["lib", _app, _ctx, _ | _rest] -> true
      _ -> false
    end
  end

  @dto_suffixes [
    "_dto.ex",
    "_request.ex",
    "_response.ex",
    "_event.ex",
    "_command.ex",
    "_payload.ex"
  ]

  defp explicit_dto_module?(file) do
    Enum.any?(@dto_suffixes, &String.ends_with?(file, &1))
  end

  @view_markers [
    "_json.ex",
    "_view.ex",
    "/json/",
    "/views/",
    "/serializers/",
    "_serializer.ex"
  ]

  defp view_module?(file) do
    Enum.any?(@view_markers, &String.contains?(file, &1))
  end

  defp find_overbroad_encoder(file, ast) do
    {_, hits} =
      Macro.prewalk(ast, [], fn
        {:defmodule, meta, [_alias, [do: body]]} = node, acc ->
          {node, classify_module(meta, body, file, acc)}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(hits)
  end

  defp classify_module(meta, body, file, acc) do
    body_list = unwrap_block(body)

    case has_bare_jason_encoder?(body_list) and has_defstruct?(body_list) do
      true -> [build_diagnostic(file, meta) | acc]
      false -> acc
    end
  end

  defp unwrap_block({:__block__, _, items}) when is_list(items), do: items
  defp unwrap_block(single), do: [single]

  # §§ elixir-implementing: §5.2, §10.4 — multi-clause head dispatch on the
  # @derive AST shape. We accept any of these as "explicit shape" (NOT bare):
  #   - {:{}, _, [Jason.Encoder, [only: ...]]}     - 3-arg tuple form
  #   - {Jason.Encoder, opts}                       - 2-tuple form
  # The bare form `@derive Jason.Encoder` parses as `{:__aliases__, _, [...]}`.
  defp has_bare_jason_encoder?(body_list) do
    Enum.any?(body_list, fn
      {:@, _, [{:derive, _, [{:__aliases__, _, [:Jason, :Encoder]}]}]} -> true
      {:@, _, [{:derive, _, [{:__aliases__, _, [:Encoder]}]}]} -> true
      _ -> false
    end)
  end

  defp has_defstruct?(body_list) do
    Enum.any?(body_list, fn
      {:defstruct, _, _} -> true
      _ -> false
    end)
  end

  defp build_diagnostic(file, meta) do
    Diagnostic.warning("1.22",
      title: "Internal struct derives bare Jason.Encoder",
      message:
        "An internal struct uses `@derive Jason.Encoder` without `:only` / " <>
          "`:except`. Every struct field — including ones added later — silently " <>
          "becomes part of the JSON API.",
      why:
        "Bare @derive Jason.Encoder encodes ALL fields. Internal modules evolve " <>
          "their field list freely; once the struct is JSON, every field rename " <>
          "or addition is a public-API change. Renaming `:user_id` to `:owner_id` " <>
          "becomes a breaking change against external consumers, even though the " <>
          "module was nominally internal.",
      alternatives: [
        Fix.new(
          summary: "Use @derive {Jason.Encoder, only: [...]} listing the public fields",
          detail:
            "Place `@derive {Jason.Encoder, only: [:id, :name, :status]}` before " <>
              "defstruct. Adding a new field to defstruct no longer changes the " <>
              "JSON shape — it must be added to :only deliberately.",
          applies_when:
            "The struct is genuinely the right shape for the JSON, just needs " <>
              "an explicit field list."
        ),
        Fix.new(
          summary: "Move encoding to a dedicated *_json.ex / *_dto.ex module",
          detail:
            "Define `MyApp.OrdersJSON.encode/1` (or a DTO struct in *_dto.ex) " <>
              "that translates the internal struct to the wire shape. The wire " <>
              "shape evolves independently; the internal struct stays private.",
          applies_when:
            "The internal struct's fields don't all belong on the wire (private " <>
              "computation cache, internal foreign keys, association loaded states)."
        ),
        Fix.new(
          summary: "If the struct IS your public DTO, move it to the context's top level",
          detail:
            "If the struct is intentionally the public shape, define it in " <>
              "`lib/my_app/orders.ex` (or a `*_dto.ex` in the same dir) so the " <>
              "intent is visible. The rule skips top-level context modules and " <>
              "files ending in `_dto.ex`/`_request.ex`/`_response.ex` etc.",
          applies_when: "The struct really is part of the public API surface."
        )
      ],
      tags: [:contract, :boundary],
      file: file,
      line: AST.line(meta)
    )
  end
end
