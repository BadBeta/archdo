defmodule Archdo.Rules.Module.UnprotectedExternalCall do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "4.20"

  @impl true
  def description, do: "External service calls should not use bang functions in production code"

  @bang_calls [
    {[:HTTPoison], [:get!, :post!, :put!, :patch!, :delete!, :head!, :options!, :request!]},
    {[:Req], [:get!, :post!, :put!, :patch!, :delete!, :request!]},
    {[:Finch], [:request!]},
    {[:Tesla], [:get!, :post!, :put!, :patch!, :delete!, :head!, :request!]},
    {[:ExAws], [:request!]},
    {[:Swoosh, :Mailer], [:deliver!]},
    {[:Bamboo, :Mailer], [:deliver_now!, :deliver_later!]}
  ]

  @impl true
  def analyze(file, ast, _opts) do
    case test_or_adapter?(file) do
      true -> []
      false -> find_bang_calls(file, ast)
    end
  end

  defp find_bang_calls(file, ast) do
    calls =
      AST.find_all(ast, fn
        {{:., _, [{:__aliases__, _, mod_parts}, func]}, _, _} -> bang_call?(mod_parts, func)
        _ -> false
      end)

    for {{:., _, [{:__aliases__, _, mod_parts}, func]}, meta, _} <- calls do
      service = Enum.map_join(mod_parts, ".", &to_string/1)
      non_bang = func |> to_string() |> String.trim_trailing("!")

      Diagnostic.warning("4.20",
        title: "External service call uses bang function",
        message:
          "#{service}.#{func}() will raise on failure instead of returning an error tuple",
        why:
          "Bang functions raise exceptions when the external service returns an error or is " <>
            "unreachable. In production, external services fail regularly — DNS timeouts, 503s, " <>
            "rate limits, connection resets. A raised exception crashes the calling process. " <>
            "Using the non-bang variant with pattern matching lets you degrade gracefully.",
        alternatives: [
          Fix.new(
            summary: "Use #{service}.#{non_bang}() and pattern match on the result",
            detail:
              "Replace `#{service}.#{func}(...)` with `case #{service}.#{non_bang}(...) do " <>
                "{:ok, response} -> handle(response); {:error, reason} -> handle_error(reason) end`.",
            applies_when: "The caller should handle failures gracefully."
          ),
          Fix.new(
            summary: "Wrap in try/rescue if crash semantics are intentional",
            detail:
              "If this code genuinely wants to crash on failure (e.g., inside a supervised " <>
                "worker that retries), keep the bang but document the intent.",
            applies_when: "The process is supervised and crash-restart is the recovery strategy."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#4.20"],
        context: %{service: service, function: func},
        file: file,
        line: AST.line(meta)
      )
    end
  end

  defp bang_call?(mod_parts, func) do
    Enum.any?(@bang_calls, fn {mod, funcs} ->
      mod_parts == mod and func in funcs
    end)
  end

  defp test_or_adapter?(file) do
    String.contains?(file, "/test/") or
      String.starts_with?(file, "test/") or
      String.contains?(file, "/adapter") or
      String.contains?(file, "/adapters/") or
      String.contains?(file, "/infrastructure/") or
      String.ends_with?(file, "_adapter.ex") or
      String.ends_with?(file, "_client.ex")
  end
end
