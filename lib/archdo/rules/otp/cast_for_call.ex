defmodule Archdo.Rules.OTP.CastForCall do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.13"

  @impl true
  def description, do: "GenServer.cast used where call is needed"

  @error_prone_patterns [
    # Repo operations
    {[:Repo], [:insert, :insert!, :update, :update!, :delete, :delete!]},
    # Known external patterns
    {[:Repo], [:transaction]}
  ]

  @result_suggesting_names ~w(create update delete register save remove)a

  @impl true
  def analyze(file, ast, _opts) do
    if not AST.genserver_module?(ast) do
      []
    else
      callbacks = AST.extract_callbacks(ast)

      (callbacks[:handle_cast] || [])
      |> Enum.flat_map(fn {meta, args, body} ->
        check_cast(file, meta, args, body)
      end)
    end
  end

  defp check_cast(file, meta, args, body) do
    issues = find_error_prone_calls(body) ++ check_message_name(args)

    if issues != [] do
      reason = Enum.join(issues, ", ")

      [
        Diagnostic.info("5.13",
          title: "Cast used where call is needed",
          message: "handle_cast contains #{reason}",
          why:
            "GenServer.cast is fire-and-forget: it has no return value and no backpressure. If the operation " <>
              "fails the caller never finds out, errors are swallowed silently, and the mailbox can grow " <>
              "without bound because casts never block. For operations whose result the caller actually needs " <>
              "(database writes, validation, anything named create/update/delete), call is the correct primitive.",
          alternatives: [
            Fix.new(
              summary: "Switch the API to GenServer.call",
              detail:
                "Replace the public API function with one that uses `GenServer.call/3`. The handle_cast clause " <>
                  "becomes handle_call returning `{:reply, result, state}` so the caller observes success/failure.",
              applies_when: "The caller needs to know whether the operation succeeded."
            ),
            Fix.new(
              summary: "Keep cast and emit telemetry/log on failure",
              detail:
                "If the operation truly is fire-and-forget (telemetry, cache warming) but errors should still " <>
                  "be visible, leave the cast in place and add explicit error logging or telemetry events from " <>
                  "the handle_cast body.",
              applies_when: "Loss of result is acceptable but errors should be observable."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#5.13"],
          context: %{issues: issues},
          file: file,
          line: AST.line(meta)
        )
      ]
    else
      []
    end
  end

  defp find_error_prone_calls(nil), do: []

  defp find_error_prone_calls(body) do
    repo_calls =
      AST.find_all(body, fn
        {{:., _, [{:__aliases__, _, mod_parts}, func]}, _, _} ->
          Enum.any?(@error_prone_patterns, fn {mod_suffix, funcs} ->
            List.last(mod_parts) in mod_suffix and func in funcs
          end)

        _ ->
          false
      end)

    if repo_calls != [], do: ["Repo operations"], else: []
  end

  defp check_message_name(args) do
    case args do
      [{:{}, _, [name | _]} | _] when is_atom(name) ->
        if name in @result_suggesting_names, do: [":#{name} message"], else: []

      [{name, _, _} | _] when is_atom(name) ->
        if name in @result_suggesting_names, do: [":#{name} message"], else: []

      [{:__block__, _, [name]} | _] when is_atom(name) ->
        if name in @result_suggesting_names, do: [":#{name} message"], else: []

      _ ->
        []
    end
  end
end
