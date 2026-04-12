defmodule Archdo.Rules.Module.SingleImplProtocol do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{Diagnostic, Fix}

  @impl true
  def id, do: "4.2"

  @impl true
  def description, do: "Protocols with only one implementation may be over-engineering"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc """
  Project-level analysis. Takes a map of protocol_name => [impl_types].
  Built by scanning all files for defprotocol and defimpl.
  """
  def analyze_project(protocol_impls, file_map) do
    protocol_impls
    |> Enum.filter(fn {_protocol, impls} -> length(impls) == 1 end)
    |> Enum.map(fn {protocol, [impl]} ->
      file = Map.get(file_map, protocol, "unknown")

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
                "in `test/support`), the protocol is justified. Document the plan in a moduledoc and add to freeze.",
            applies_when: "There's a documented plan for more implementations."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#4.2"],
        context: %{protocol: to_string(protocol), implementation: to_string(impl)},
        file: file,
        line: 1
      )
    end)
  end
end
