defmodule Archdo.Rules.Module.RescueSwallowsError do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.9"

  @impl true
  def description, do: "Bare rescue clauses that swallow errors silently"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      find_swallowing_rescues(file, ast)
    end
  end

  defp find_swallowing_rescues(file, ast) do
    AST.find_all(ast, fn
      # rescue _ -> <something that isn't Logger or reraise>
      {:rescue, clauses} when is_list(clauses) ->
        Enum.any?(clauses, &swallows_error?/1)

      _ ->
        false
    end)
    |> Enum.map(fn {:rescue, clauses} ->
      # Get line from the first swallowing clause
      line =
        clauses
        |> Enum.filter(&swallows_error?/1)
        |> Enum.map(fn {:->, meta, _} -> AST.line(meta) end)
        |> List.first(1)

      build_diagnostic(file, line, classify_rescue(clauses))
    end)
  end

  # A rescue clause swallows an error if:
  # 1. It catches a wildcard (_ or _e) AND
  # 2. The body doesn't log, reraise, or return an error tuple
  defp swallows_error?({:->, _, [pattern, body]}) do
    catches_wildcard?(pattern) and not propagates_error?(body)
  end

  defp swallows_error?(_), do: false

  defp catches_wildcard?([{:_, _, _}]), do: true
  defp catches_wildcard?([{name, _, ctx}]) when is_atom(name) and is_atom(ctx) do
    name |> Atom.to_string() |> String.starts_with?("_")
  end
  # rescue e -> (no module filter)
  defp catches_wildcard?([{name, _, ctx}]) when is_atom(name) and is_atom(ctx), do: true
  # rescue e in [...] with broad list
  defp catches_wildcard?(_), do: false

  defp propagates_error?(body) do
    AST.contains?(body, fn
      # Logger calls
      {{:., _, [{:__aliases__, _, [:Logger]}, _]}, _, _} -> true
      # reraise
      {:reraise, _, _} -> true
      # {:error, _} tuple return
      {:{}, _, [{:__block__, _, [:error]} | _]} -> true
      {:error, _} -> true
      _ -> false
    end)
  end

  defp classify_rescue(clauses) do
    swallowing = Enum.filter(clauses, &swallows_error?/1)

    cond do
      Enum.any?(swallowing, fn {:->, _, [_, body]} -> returns_default?(body) end) ->
        :returns_default

      Enum.any?(swallowing, fn {:->, _, [_, body]} -> returns_empty?(body) end) ->
        :returns_empty

      true ->
        :discards
    end
  end

  defp returns_default?(body) do
    AST.contains?(body, fn
      {:__block__, _, [val]} when val in [nil, [], %{}, false, 0, ""] -> true
      val when val in [nil, [], false, 0] -> true
      _ -> false
    end)
  end

  defp returns_empty?(body), do: returns_default?(body)

  defp build_diagnostic(file, line, kind) do
    {message, detail} =
      case kind do
        :returns_default ->
          {"rescue clause catches all exceptions and returns a default value",
           "The exception is swallowed and a default (nil, [], %{}) is returned. The caller has " <>
             "no way to know an error occurred — it sees a valid-looking result that is actually " <>
             "masking a failure. If the rescue is protecting against a known error, catch that " <>
             "specific exception type and return {:error, reason}."}

        :returns_empty ->
          {"rescue clause catches all exceptions and returns an empty value",
           "Same as returning a default — the error is invisible to the caller."}

        :discards ->
          {"rescue clause catches all exceptions without logging or propagating",
           "The exception is caught and discarded entirely. The caller sees whatever the rescue " <>
             "body returns, with no indication that an error occurred. At minimum, add Logger.warning."}
      end

    Diagnostic.warning("6.9",
      title: "Rescue swallows error silently",
      message: message,
      why:
        "Elixir's error handling philosophy is 'let it crash' for processes (supervisors restart them) " <>
          "and ok/error tuples for function-level errors. A bare rescue that swallows exceptions combines " <>
          "the worst of both worlds: the error is not propagated (so callers can't handle it), the process " <>
          "doesn't crash (so the supervisor doesn't restart it), and no log is produced (so nobody knows " <>
          "it happened). Silent failures accumulate into mysterious behaviour that's impossible to debug.",
      alternatives: [
        Fix.new(
          summary: "Remove the rescue and let the process crash",
          detail:
            "If this code runs inside a supervised process (GenServer, Task), removing the rescue is " <>
              "often the best answer. The process crashes, the supervisor restarts it, and the error is " <>
              "logged automatically. This is the OTP way.",
          applies_when: "The code runs in a supervised process and a restart is acceptable."
        ),
        Fix.new(
          summary: "Convert to {:ok, _} / {:error, reason} and let the caller decide",
          detail: detail,
          example: """
          ```elixir
          # BEFORE — error is invisible
          def parse(input) do
            do_parse(input)
          rescue
            _ -> nil
          end

          # AFTER — caller can handle it
          def parse(input) do
            {:ok, do_parse(input)}
          rescue
            e -> {:error, Exception.message(e)}
          end
          ```
          """,
          applies_when: "The caller needs to know about the failure."
        ),
        Fix.new(
          summary: "Catch a specific exception type instead of everything",
          detail:
            "If you know which exception you're protecting against (ArgumentError, File.Error, " <>
              "Jason.DecodeError), catch only that. Other exceptions propagate naturally, and the " <>
              "rescue clause documents exactly what error condition is expected.",
          example: """
          ```elixir
          # BEFORE — catches everything
          rescue _ -> []

          # AFTER — catches only what's expected
          rescue
            e in [File.Error] ->
              Logger.warning("file not found: \#{inspect(e)}")
              []
          end
          ```
          """,
          applies_when: "Only one or two specific exceptions are expected."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.9"],
      context: %{kind: kind},
      file: file,
      line: line
    )
  end
end
