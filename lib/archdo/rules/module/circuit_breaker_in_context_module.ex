defmodule Archdo.Rules.Module.CircuitBreakerInContextModule do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "1.36"

  @impl true
  def description,
    do:
      "Circuit breaker call (Fuse / ExBreaker / etc.) inside a context module — " <>
        "infrastructure concerns belong in the adapter, not in domain code"

  # Adapter / boundary suffixes that ARE allowed to host circuit-breaker calls.
  @adapter_suffixes [
    "_adapter",
    "_client",
    "_gateway",
    "_api",
    "_proxy",
    "_repository"
  ]

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) or adapter_path?(file) do
      true -> []
      false -> find_breaker_calls(file, ast)
    end
  end

  defp adapter_path?(file) do
    base =
      file
      |> Path.basename()
      |> Path.rootname()

    Enum.any?(@adapter_suffixes, &String.ends_with?(base, &1))
  end

  defp find_breaker_calls(file, ast) do
    ast
    |> AST.find_all(&breaker_call?/1)
    |> Enum.map(fn node -> build_diagnostic(file, line_of(node), name_of(node)) end)
  end

  # `:fuse.ask/2`, `:fuse.install/2`, etc.
  defp breaker_call?({{:., _, [:fuse, fun]}, _, _}) when is_atom(fun), do: true

  # `ExBreaker.run/2`, `ExBreaker.ask/1`
  defp breaker_call?({{:., _, [{:__aliases__, _, [:ExBreaker]}, _]}, _, _}), do: true

  # `Fuse.ask/...` aliased
  defp breaker_call?({{:., _, [{:__aliases__, _, [:Fuse]}, _]}, _, _}), do: true

  defp breaker_call?(_), do: false

  defp line_of({_, meta, _}), do: AST.line(meta)

  defp name_of({{:., _, [:fuse, fun]}, _, _}), do: ":fuse.#{fun}"

  defp name_of({{:., _, [{:__aliases__, _, parts}, fun]}, _, _}),
    do: "#{Enum.join(parts, ".")}.#{fun}"

  defp name_of(_), do: "circuit-breaker call"

  defp build_diagnostic(file, line, call) do
    Diagnostic.warning("1.36",
      title: "Circuit breaker `#{call}` in context module — move to adapter",
      message:
        "Circuit-breaker calls (Fuse, ExBreaker, similar) sit between domain code " <>
          "and an external service. They are infrastructure: their parameters " <>
          "(threshold, reset window) and lifecycle (`install`, `ask`, `melt`, " <>
          "`reset`) describe the FAULT model of the external dependency, not the " <>
          "domain. Hosting them in a context module (`MyApp.Billing`) couples " <>
          "domain logic to a specific resilience library and crowds out the " <>
          "business decisions the context exists to express.",
      why:
        "Hexagonal / ports-and-adapters places the circuit breaker INSIDE the " <>
          "adapter that wraps the external service. The context calls the adapter " <>
          "behaviour and pattern-matches on its `{:ok, _}` / `{:error, " <>
          ":unavailable}` return — completely unaware that a breaker exists. " <>
          "Benefits: (1) you can swap or remove the breaker without touching " <>
          "domain code, (2) the test mock for the adapter doesn't need to know " <>
          "about breakers, (3) the domain stays focused on business rules.",
      alternatives: [
        Fix.new(
          summary: "Move the breaker into a Stripe adapter module",
          detail:
            "# lib/my_app/billing.ex (context — no breaker)\n" <>
              "def charge(card, amount), do: Billing.gateway().charge(card, amount)\n\n" <>
              "# lib/my_app/billing/gateway.ex (behaviour)\n" <>
              "@callback charge(Card.t(), pos_integer()) ::\n" <>
              "  {:ok, Charge.t()} | {:error, term()}\n\n" <>
              "# lib/my_app/billing/stripe_adapter.ex (adapter — breaker lives here)\n" <>
              "@behaviour MyApp.Billing.Gateway\n" <>
              "def charge(card, amount) do\n" <>
              "  case :fuse.ask(:stripe_breaker, :sync) do\n" <>
              "    :ok -> Stripe.charge(card, amount)\n" <>
              "    :blown -> {:error, :unavailable}\n" <>
              "  end\nend",
          applies_when: "Always — adapters are the right home for breakers."
        )
      ],
      references: [
        "elixir-planning/SKILL.md#11.2",
        "elixir-planning/SKILL.md#1.16",
        "elixir-implementing/SKILL.md#10.2"
      ],
      context: %{call: call},
      file: file,
      line: line
    )
  end
end
