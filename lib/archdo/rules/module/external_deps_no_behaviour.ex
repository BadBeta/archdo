defmodule Archdo.Rules.Module.ExternalDepsNoBehaviour do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "4.4"

  @impl true
  def description, do: "External service calls should go through a behaviour boundary"

  @external_services [
    # HTTP clients
    [:HTTPoison], [:Finch], [:Req], [:Tesla], [:Mint, :HTTP],
    # Email
    [:Swoosh, :Mailer], [:Bamboo, :Mailer],
    # AWS
    [:ExAws], [:ExAws, :S3], [:ExAws, :SQS], [:ExAws, :SNS],
    # Stripe
    [:Stripity, :Stripe], [:Stripe],
    # Twilio
    [:ExTwilio]
  ]

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) or adapter_file?(file) or infrastructure_file?(file) do
      []
    else
      find_direct_external_calls(file, ast)
    end
  end

  defp find_direct_external_calls(file, ast) do
    caller_module = AST.extract_module_name(ast)

    AST.find_all(ast, fn
      {{:., _, [{:__aliases__, _, mod_parts}, _func]}, _meta, _args} ->
        mod_parts in @external_services and not AST.self_call?(caller_module, mod_parts)

      _ ->
        false
    end)
    |> Enum.uniq_by(fn {{:., _, [{:__aliases__, _, mod_parts}, _]}, _, _} -> mod_parts end)
    |> Enum.map(fn {{:., _, [{:__aliases__, _, mod_parts}, _func]}, meta, _} ->
      service = Enum.join(mod_parts, ".")

      Diagnostic.warning("4.4",
        title: "External service call without adapter boundary",
        message: "Module calls #{service} directly instead of going through a behaviour adapter",
        why:
          "Direct calls to HTTP clients, payment processors, mailers, or AWS SDKs hardcode the implementation " <>
            "into business code. Tests have to either spin up the real client (slow, flaky, expensive) or " <>
            "monkey-patch with global mocks. Worse, swapping providers later means hunting through every call " <>
            "site instead of changing one adapter module.",
        alternatives: [
          Fix.new(
            summary: "Define a behaviour and implement an adapter that wraps #{service}",
            detail:
              "Create a behaviour describing what your code actually needs from the external service " <>
                "(`MyApp.Mailer.send_email/3`, etc.). Implement it in an adapter module that delegates to " <>
                "#{service}. Configure the implementation via Application env so tests can swap in a Mox-backed mock.",
            example: """
            ```elixir
            # Behaviour
            defmodule MyApp.Mailer do
              @callback send_email(to :: String.t(), subject :: String.t(), body :: String.t()) :: :ok
            end

            # Adapter
            defmodule MyApp.Mailer.Swoosh do
              @behaviour MyApp.Mailer
              def send_email(to, subject, body), do: # ...
            end

            # config
            config :my_app, :mailer, MyApp.Mailer.Swoosh
            ```
            """,
            applies_when: "The external service is testable behind a small interface."
          ),
          Fix.new(
            summary: "Move the call into the existing infrastructure/adapter layer",
            detail:
              "If you already have an adapters/ or infrastructure/ namespace, move the offending call there. " <>
                "Domain code calls into the adapter via the project's existing pattern instead of touching the " <>
                "external SDK directly.",
            applies_when: "The codebase already has an adapter pattern in place."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#4.4"],
        context: %{service: service},
        file: file,
        line: AST.line(meta)
      )
    end)
  end

  defp adapter_file?(file) do
    String.contains?(file, "/adapters/") or String.contains?(file, "/adapter/") or
      String.contains?(file, "/impl/") or String.contains?(file, "/clients/") or
      String.contains?(file, "/infrastructure/")
  end

  defp infrastructure_file?(file) do
    String.contains?(file, "/mailer") or String.ends_with?(file, "_client.ex")
  end

end
