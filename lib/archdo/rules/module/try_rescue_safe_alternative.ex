defmodule Archdo.Rules.Module.TryRescueSafeAlternative do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.78"

  @impl true
  def description,
    do: "try/rescue around a raising call that has a non-raising alternative — use it"

  # Map of raising calls to their safe alternatives. Detection: when
  # a try-block body contains one of these calls, fire and name the
  # alternative.
  @safe_alternatives %{
    # `String.to_integer/1` raises ArgumentError on non-numeric input.
    {[:String], :to_integer} => "Integer.parse/1 (returns {int, rest} | :error)",
    # `String.to_atom/1` raises on... well it doesn't, but the
    # safe alternative for unknown atoms is to_existing_atom.
    {[:String], :to_atom} => "String.to_existing_atom/1 (raises only for unknown atoms)",
    # `Map.fetch!` raises KeyError on missing key.
    {[:Map], :fetch!} => "Map.fetch/2 (returns {:ok, value} | :error)",
    # `Keyword.fetch!` raises KeyError on missing key.
    {[:Keyword], :fetch!} => "Keyword.fetch/2 (returns {:ok, value} | :error)",
    # `Repo.get!` / `Repo.one!` / `Repo.fetch!` raise Ecto.NoResultsError.
    {[:Repo], :get!} => "Repo.get/2 (returns nil for not-found)",
    {[:Repo], :one!} => "Repo.one/1 (returns nil for not-found)",
    # `File.read!` raises File.Error.
    {[:File], :read!} => "File.read/1 (returns {:ok, binary} | {:error, posix})",
    {[:File], :stat!} => "File.stat/1 (returns {:ok, stat} | {:error, posix})"
  }

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    AST.find_all(ast, &try_with_safe_alternative_inside?/1)
    |> Enum.flat_map(fn {:try, meta, args} ->
      case raising_call_inside(args) do
        nil -> []
        {alternative, line} -> [build_diagnostic(file, line || AST.line(meta), alternative)]
      end
    end)
  end

  defp try_with_safe_alternative_inside?({:try, _, args}) when is_list(args) do
    raising_call_inside(args) != nil
  end

  defp try_with_safe_alternative_inside?(_), do: false

  defp raising_call_inside(args) do
    body = try_body(args)

    {_, hit} =
      Macro.prewalk(body, nil, fn
        {{:., _, [{:__aliases__, _, mod_parts}, fun]}, meta, _call_args} = node, nil ->
          case Map.get(@safe_alternatives, normalized_key(mod_parts, fun)) do
            nil -> {node, nil}
            alt -> {node, {alt, AST.line(meta)}}
          end

        node, acc ->
          {node, acc}
      end)

    hit
  end

  # Match alias by its TAIL — e.g., `MyApp.Repo` matches `[:Repo]` from
  # the safe-alternatives table because `Repo` is the meaningful tail.
  defp normalized_key(mod_parts, fun) when is_list(mod_parts) do
    {[List.last(mod_parts)], fun}
  end

  defp try_body(args) do
    Enum.find_value(args, [], fn
      [{:do, body} | _] -> body
      _ -> nil
    end)
  end

  defp build_diagnostic(file, line, alternative) do
    Diagnostic.info("6.78",
      title: "try/rescue around a raising call with a safe alternative",
      message:
        "This try/rescue wraps a call that has a non-raising alternative: #{alternative}. " <>
          "Reach for the safe variant and pattern-match on the result instead.",
      why:
        "try/rescue is for genuinely-exceptional cases. When the standard library already " <>
          "exposes a `{:ok, _} | :error` (or `{:ok, _} | {:error, _}`) alternative, that's " <>
          "the canonical 'expected-failure' path. Pattern-matching on the result composes " <>
          "with `with` chains; rescue does not.",
      alternatives: [
        Fix.new(
          summary: "Use the safe alternative + pattern match",
          detail:
            "case Integer.parse(s) do\n" <>
              "  {n, \"\"} -> {:ok, n}\n" <>
              "  _ -> :error\n" <>
              "end\n" <>
              "# vs:\n" <>
              "try do\n" <>
              "  {:ok, String.to_integer(s)}\n" <>
              "rescue\n" <>
              "  _ -> :error\n" <>
              "end",
          applies_when: "Always — the safe variant is what the stdlib exposes for this case."
        )
      ],
      references: ["elixir-implementing/SKILL.md#2.4", "elixir-implementing/SKILL.md#7.4"],
      context: %{alternative: alternative},
      file: file,
      line: line
    )
  end
end
