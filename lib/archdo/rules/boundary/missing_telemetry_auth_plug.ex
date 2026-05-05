defmodule Archdo.Rules.Boundary.MissingTelemetryAuthPlug do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "4.21"

  @impl true
  def description, do: "Auth plug without telemetry — security-critical operations are invisible"

  @auth_filename_keywords ["auth", "authentication", "authenticate", "session", "login"]
  @auth_body_calls [:verify_password, :verify_token, :authenticate_user, :sign_in, :authorize]

  @impl true
  def analyze(file, ast, _opts) do
    cond do
      AST.test_file?(file) -> []
      AST.has_marker?(ast, :archdo_no_observability) -> []
      not auth_plug?(file, ast) -> []
      AST.contains_telemetry?(ast) or AST.contains_logger?(ast) -> []
      true -> [build_diagnostic(file)]
    end
  end

  defp auth_plug?(file, ast) do
    plug_module?(file, ast) and (auth_named?(file) or auth_calls_in_body?(ast))
  end

  defp plug_module?(file, ast) do
    String.contains?(file, "/plugs/") or behaviour?(ast, [:Plug]) or use_form?(ast)
  end

  defp use_form?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {:use, _, [{:__aliases__, _, parts} | _]} = node, _acc ->
          {node, parts == [:Plug, :Builder] or parts == [:Plug, :Router]}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp behaviour?(ast, target_parts) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {:@, _, [{:behaviour, _, [{:__aliases__, _, parts}]}]} = node, _acc ->
          {node, parts == target_parts}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp auth_named?(file) do
    base = file |> Path.basename() |> String.downcase()
    Enum.any?(@auth_filename_keywords, &String.contains?(base, &1))
  end

  defp auth_calls_in_body?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {name, _, args} = node, _acc when name in @auth_body_calls and is_list(args) ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp build_diagnostic(file) do
    Diagnostic.info("4.21",
      title: "Auth plug without telemetry",
      message:
        "This plug looks like it handles authentication / session operations but " <>
          "emits no telemetry or Logger calls. Auth events are security-critical and " <>
          "must be observable.",
      why:
        "Authentication failures, suspicious tokens, and authorization decisions are the " <>
          "primary signal in production-incident response. A silent auth plug means a " <>
          "compromised credential leaves no trace; a regression in token verification " <>
          "shows up as a customer-support ticket rather than an alert.",
      alternatives: [
        Fix.new(
          summary: "Wrap auth operations in :telemetry.span",
          detail:
            ":telemetry.span([:my_app, :auth, :token_verify], %{user_id: id}, fn -> " <>
              "{verify_token(token), %{}} end). Emit success / failure events that " <>
              "operators can alert on.",
          applies_when: "Always for production auth code."
        ),
        Fix.new(
          summary: "Mark @archdo_no_observability if intentional",
          detail:
            "If this plug genuinely doesn't need telemetry (rare for auth — usually a " <>
              "false-positive of the keyword detection), set the marker at module level " <>
              "with a clear reason.",
          applies_when:
            "Confirmed false positive (file name contains 'auth' but isn't " <>
              "actually auth-related)."
        )
      ],
      references: ["GUIDE.md#4.21"],
      context: %{},
      file: file,
      line: 1
    )
  end
end
