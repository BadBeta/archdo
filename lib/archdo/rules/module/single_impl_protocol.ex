defmodule Archdo.Rules.Module.SingleImplProtocol do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "4.2"

  @impl true
  def description, do: "Protocols with only one implementation may be over-engineering"

  @doc """
  Project-level analysis. Scans all files for `defprotocol` and `defimpl`
  declarations, builds a map of protocol → [implementation_types], and
  emits a finding for each protocol with exactly one implementation.

  Test files are excluded from the scan: a protocol's mock implementation
  in `test/support/` shouldn't count toward the impl tally — production
  protocols with a single prod-impl + a test mock would otherwise look
  like two-impl protocols and slip past the rule.
  """
  @spec analyze_project([{String.t(), Macro.t()}]) :: [Diagnostic.t()]
  def analyze_project(file_asts) do
    {protocols_by_file, impls_by_protocol} = aggregate(file_asts)

    for {protocol, [impl]} <- impls_by_protocol do
      file = Map.get(protocols_by_file, protocol, "unknown")
      build_diagnostic(protocol, impl, file)
    end
  end

  # Walk every production file once. For each `defprotocol Foo`, record
  # the defining file. For each `defimpl Foo, for: Bar`, append `Bar` to
  # the protocol's impl list. Returns
  # `{%{protocol => file}, %{protocol => [impl_types]}}`.
  defp aggregate(file_asts) do
    Enum.reduce(file_asts, {%{}, %{}}, &aggregate_file/2)
  end

  defp aggregate_file({file, ast}, acc) do
    case AST.test_file?(file) do
      true -> acc
      false -> walk_protocols_and_impls(ast, file, acc)
    end
  end

  defp walk_protocols_and_impls(ast, file, {by_file, by_proto}) do
    {_, result} =
      Macro.prewalk(ast, {by_file, by_proto}, fn
        {:defprotocol, _, [{:__aliases__, _, parts} | _]} = node, {bf, bp} ->
          name = AST.join_alias_parts(parts)
          {node, {Map.put(bf, name, file), bp}}

        {:defimpl, _, [{:__aliases__, _, proto_parts}, opts | _]} = node, {bf, bp}
        when is_list(opts) ->
          {node, record_impl(proto_parts, opts, bf, bp)}

        node, acc ->
          {node, acc}
      end)

    result
  end

  # The `for:` keyword may be a bare atom (`:for`) OR
  # `{:__block__, _, [:for]}` under literal_encoder. Match both.
  defp record_impl(proto_parts, opts, by_file, by_proto) do
    proto = AST.join_alias_parts(proto_parts)

    case impl_target(opts) do
      nil -> {by_file, by_proto}
      target -> {by_file, Map.update(by_proto, proto, [target], &[target | &1])}
    end
  end

  defp impl_target(opts) do
    Enum.find_value(opts, fn
      {{:__block__, _, [:for]}, target_ast} -> resolve_for_target(target_ast)
      {:for, target_ast} -> resolve_for_target(target_ast)
      _ -> nil
    end)
  end

  defp resolve_for_target({:__aliases__, _, parts}) when is_list(parts),
    do: AST.join_alias_parts(parts)

  defp resolve_for_target(_), do: nil

  defp build_diagnostic(protocol, impl, file) do
    Diagnostic.info("4.2",
      title: "Protocol with single implementation",
      message: "Protocol #{protocol} has exactly one implementation (#{impl})",
      why:
        "Protocols (and behaviours) are dispatch mechanisms that pay for themselves when there are multiple " <>
          "implementations. With one implementation the protocol adds indirection, slows down dispatch, and " <>
          "obscures the actual code path — readers have to chase from the protocol to the impl module to " <>
          "understand what's happening. Direct function calls are clearer until a second implementation arrives.",
      alternatives: [
        Fix.new(
          summary: "Inline the implementation as direct function calls",
          detail:
            "Replace the protocol with plain functions in the implementation module. Callers stop going " <>
              "through the protocol dispatch and the call graph becomes traceable. If a second implementation " <>
              "is needed later, reintroduce the protocol then.",
          applies_when: "There's no concrete plan for additional implementations."
        ),
        Fix.new(
          summary: "Keep the protocol if more implementations are imminent",
          detail:
            "If you know other implementations are coming (a planned second adapter, a test mock that lives " <>
              "in `test/support`), the protocol is justified. Document the plan in a moduledoc.",
          applies_when: "There's a documented plan for more implementations."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#4.2"],
      context: %{protocol: to_string(protocol), implementation: to_string(impl)},
      file: file,
      line: 1
    )
  end
end
