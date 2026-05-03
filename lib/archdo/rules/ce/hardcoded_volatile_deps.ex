defmodule Archdo.Rules.CE.HardcodedVolatileDeps do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-1. A volatile module that calls
  # another volatile primitive directly, without a behaviour-based
  # seam, no Mox port, and no injection of the dependency. The module
  # is in the volatile zone — Substitutability is the only mechanism
  # that buys test seam and vendor-drift insulation here, and it's
  # missing. Tests cannot exercise the module without real I/O; the
  # dependency cannot be swapped.

  alias Archdo.{AST, Diagnostic, Fix, Volatility}

  @impl true
  def id, do: "CE-1"

  @impl true
  def description, do: "Volatile module with hardcoded volatile dependency (no seam)"

  @impl true
  def analyze(file, ast, opts) do
    classification = Volatility.classification_for(file, ast, opts)

    case classification.tag do
      :volatile ->
        case has_seam?(ast) do
          true -> []
          false -> emit_findings(file, classification)
        end

      _ ->
        []
    end
  end

  # A "seam" exists when the module declares any of:
  #   - `@behaviour SomeModule` (callers can route through the behaviour)
  #   - `@callback Foo` (the module IS a behaviour)
  #   - `Application.compile_env`-bound module slot
  defp has_seam?(ast) do
    AST.contains?(ast, fn
      {:@, _, [{:behaviour, _, _}]} ->
        true

      {:@, _, [{:callback, _, _}]} ->
        true

      {{:., _, [{:__aliases__, _, [:Application]}, fun]}, _, _}
      when fun in [:compile_env, :compile_env!, :get_env, :fetch_env, :fetch_env!] ->
        true

      _ ->
        false
    end)
  end

  defp emit_findings(file, classification) do
    classification.evidence.volatile_calls
    |> Enum.uniq()
    |> Enum.map(fn {mod, fun, arity} ->
      build_diagnostic(file, mod, fun, arity)
    end)
  end

  defp build_diagnostic(file, mod, fun, arity) do
    Diagnostic.warning("CE-1",
      title: "Volatile module with hardcoded volatile dependency",
      message:
        "Direct call to #{inspect(mod)}.#{fun}/#{arity} from a volatile module " <>
          "without a behaviour seam, Mox port, or injected dependency",
      why:
        "The module is in the volatile zone — Substitutability is the only " <>
          "mechanism that buys test seam and vendor-drift insulation here, and " <>
          "it's missing. Tests cannot exercise the module without real I/O; the " <>
          "dependency cannot be swapped without touching every call site.",
      alternatives: [
        Fix.new(
          summary: "Introduce a behaviour for the dependency",
          detail:
            "Define a `@callback` describing the surface this module needs from " <>
              "#{inspect(mod)}. Add `Mox.defmock/2` in `test/test_helper.exs`. " <>
              "Route the call through the behaviour via " <>
              "`Application.compile_env!(:my_app, :http_client)`.",
          applies_when: "The dependency has a small surface this module needs."
        ),
        Fix.new(
          summary: "Pass the dependency as a function argument",
          detail:
            "Accept the dep as a parameter: `def fetch(http_client, url)`. " <>
              "Tests pass a mock; production wires the real adapter. Useful when " <>
              "only a few call sites need the seam.",
          applies_when: "The seam is needed at a few specific entry points."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-1"],
      context: %{call: "#{inspect(mod)}.#{fun}/#{arity}"},
      file: file,
      line: 1
    )
  end
end
