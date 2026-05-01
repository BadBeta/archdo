defmodule Archdo.Rules.CE.OkLosesInfo do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-50. A function that performs work
  # producing a richer result (`{:ok, value}`, an HTTP response, an
  # inserted struct) but discards it and returns the bare atom `:ok`
  # forces callers to re-fetch the value or accept blindness about
  # what happened. The contract is wrong — the function knows more
  # than it tells.

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "CE-50"

  @impl true
  def description, do: "Function returns :ok but discards a richer last-expression result"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) or fire_and_forget?(ast) do
      true -> []
      false -> find_lossy_ok_returns(file, ast)
    end
  end

  defp fire_and_forget?(ast) do
    AST.contains?(ast, fn
      {:@, _, [{:archdo_fire_and_forget, _, _}]} -> true
      _ -> false
    end)
  end

  defp find_lossy_ok_returns(file, ast) do
    ast
    |> AST.extract_functions(:public)
    |> Enum.flat_map(fn {name, arity, meta, _args, body} ->
      case body && body_returns_lossy_ok?(body) do
        true -> [build_diagnostic(file, name, arity, meta)]
        _ -> []
      end
    end)
  end

  # The body returns the literal atom `:ok` AND the second-to-last
  # statement is a call that returns a richer result (Repo.insert/etc.).
  defp body_returns_lossy_ok?(body) do
    statements = body_statements(body)

    case List.last(statements) do
      {:__block__, _, [:ok]} -> richer_call_before_ok?(statements)
      :ok -> richer_call_before_ok?(statements)
      _ -> false
    end
  end

  # extract_functions returns body as the def's keyword list — unwrap
  # the `:do` value (which itself may or may not be a `:__block__`).
  defp body_statements(body) when is_list(body) do
    case Keyword.get(body, :do) do
      nil -> []
      {:__block__, _, statements} when is_list(statements) -> statements
      single -> [single]
    end
  end

  defp body_statements({:__block__, _, statements}) when is_list(statements), do: statements
  defp body_statements(single), do: [single]

  defp richer_call_before_ok?(statements) do
    case Enum.split(statements, -1) do
      {[], _} ->
        false

      {prefix, _last} ->
        Enum.any?(prefix, &richer_result_call?/1)
    end
  end

  # A "richer result" call is a remote call to one of the well-known
  # tuple-returning APIs OR a pattern-match assertion of {:ok, _} on
  # a function call (`{:ok, _user} = Repo.insert(...)` — the value is
  # being captured AND then thrown away when the function returns :ok).
  @richer_modules [
    [:Repo],
    [:Ecto, :Repo],
    [:HTTPoison],
    [:Req],
    [:Tesla],
    [:Finch],
    [:Mailer],
    [:Swoosh, :Mailer]
  ]

  defp richer_result_call?({:=, _, [{:{}, _, [{:__block__, _, [:ok]}, _]}, _rhs]}), do: true
  defp richer_result_call?({:=, _, [{:__block__, _, [{tuple_pattern, _}]}, _rhs]}) do
    case tuple_pattern do
      {:__block__, _, [:ok]} -> true
      :ok -> true
      _ -> false
    end
  end

  defp richer_result_call?({:=, _, [pattern, _rhs]}) do
    case pattern do
      {{:__block__, _, [:ok]}, _} -> true
      {:ok, _} -> true
      _ -> false
    end
  end

  defp richer_result_call?(
         {{:., _, [{:__aliases__, _, parts}, _fun]}, _, _}
       )
       when is_list(parts) do
    parts in @richer_modules
  end

  defp richer_result_call?(_), do: false

  defp build_diagnostic(file, name, arity, meta) do
    Diagnostic.warning("CE-50",
      title: "Function returns :ok but discards richer result",
      message:
        "#{name}/#{arity} returns :ok after a call producing a richer result " <>
          "(an inserted struct, an HTTP response, etc.) — callers can't tell " <>
          "what happened",
      why:
        "Returning the bare atom `:ok` after a `Repo.insert/1` (or HTTP call, or " <>
          "any tuple-returning operation) means callers cannot distinguish " <>
          "'operation succeeded with this result' from 'operation succeeded with " <>
          "no result.' Subsequent operations needing the result must re-fetch; " <>
          "tests cannot assert on what was created.",
      alternatives: [
        Fix.new(
          summary: "Return the meaningful value",
          detail:
            "Replace `:ok` with `{:ok, value}` (the result of the inner call). " <>
              "If callers prefer the simpler shape, give them a separate " <>
              "convenience function that wraps the richer one.",
          applies_when: "The richer value is useful to at least one caller."
        ),
        Fix.new(
          summary: "Mark as fire-and-forget",
          detail:
            "If the operation is genuinely fire-and-forget (cache invalidation, " <>
              "notification dispatch where the result is uninteresting), declare " <>
              "the contract: add `@archdo_fire_and_forget true` at module level.",
          applies_when: "Callers truly cannot use the richer result."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-50"],
      context: %{function: "#{name}/#{arity}"},
      file: file,
      line: AST.line(meta)
    )
  end
end
