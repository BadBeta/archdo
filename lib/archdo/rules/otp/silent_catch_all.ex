defmodule Archdo.Rules.OTP.SilentCatchAll do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.14"

  @impl true
  def description, do: "handle_info catch-all must not swallow messages silently"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.genserver_module?(ast) do
      false ->
        []

      true ->
        callbacks = AST.extract_callbacks(ast)

        (callbacks[:handle_info] || [])
        |> Enum.filter(&catch_all_clause?/1)
        |> Enum.reject(&has_logging?/1)
        |> Enum.map(fn {meta, _args, _body} ->
          Diagnostic.info("5.14",
            title: "Silent handle_info catch-all",
            message: "A catch-all handle_info clause discards messages without logging",
            why:
              "The catch-all swallows everything that doesn't match a more specific clause — including monitor " <>
                ":DOWN messages, :EXIT signals from linked processes, and SSL info messages. The symptoms appear " <>
                "far from the cause: monitored processes die unnoticed, links fire and the GenServer keeps running " <>
                "with stale references. Since Elixir 1.15+ the default GenServer implementation already logs " <>
                "unhandled messages, so the catch-all is usually pure noise.",
            alternatives: [
              Fix.new(
                summary:
                  "Delete the catch-all and let GenServer's default log unexpected messages",
                detail:
                  "Removing the clause is the safest option. Elixir 1.15+ logs unhandled handle_info messages " <>
                    "via Logger and includes the module name and message, which is exactly the visibility this " <>
                    "rule is asking for.",
                applies_when:
                  "You're on Elixir 1.15+ (the default behaviour logs unhandled messages)."
              ),
              Fix.new(
                summary: "Add explicit Logger.warning to the catch-all",
                detail:
                  "If you need a custom log format or are on older Elixir, add `Logger.warning(\"\#{__MODULE__} \" <> " <>
                    "\"unexpected message: \#{inspect(msg)}\")` so unmatched messages are at least visible.",
                applies_when: "You need a custom log message or run pre-1.15 Elixir."
              )
            ],
            references: ["ARCHITECTURE_RULES.md#5.14"],
            context: %{},
            file: file,
            line: AST.line(meta)
          )
        end)
    end
  end

  defp catch_all_clause?({_meta, args, _body}) do
    case args do
      # handle_info(msg, state) or handle_info(_msg, state) — wildcard first arg
      [first_arg | _] -> wildcard_arg?(first_arg)
      _ -> false
    end
  end

  defp wildcard_arg?({name, _, context}) when is_atom(name) and is_atom(context) do
    name
    |> Atom.to_string()
    |> String.starts_with?("_")
  end

  # Bare _ variable
  defp wildcard_arg?({:_, _, _}), do: true
  defp wildcard_arg?(_), do: false

  defp has_logging?({_meta, _args, body}) do
    AST.contains?(body, fn
      {{:., _, [{:__aliases__, _, [:Logger]}, _func]}, _, _} -> true
      {:require, _, [{:__aliases__, _, [:Logger]} | _]} -> true
      _ -> false
    end)
  end
end
