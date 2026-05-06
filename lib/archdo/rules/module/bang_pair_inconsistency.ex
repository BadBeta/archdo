defmodule Archdo.Rules.Module.BangPairInconsistency do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "1.35"

  @impl true
  def description,
    do:
      "Bang variant `foo!/N` defined without companion `foo/N` — convention is " <>
        "to ship both: non-bang returns ok/error, bang raises"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_bang_orphans(file, ast)
    end
  end

  defp find_bang_orphans(file, ast) do
    funs = AST.extract_functions(ast, :public)

    sigs =
      funs
      |> Enum.map(fn {name, arity, _, _, _} -> {Atom.to_string(name), arity} end)
      |> MapSet.new()

    funs
    |> Enum.filter(fn {name, arity, _, _, _} ->
      bang_orphan?(Atom.to_string(name), arity, sigs)
    end)
    |> Enum.uniq_by(fn {name, arity, _, _, _} -> {name, arity} end)
    |> Enum.map(fn {name, arity, meta, _, _} -> build_diagnostic(file, name, arity, meta) end)
  end

  defp bang_orphan?(name_str, arity, sigs) do
    case String.ends_with?(name_str, "!") do
      false -> false
      true -> not MapSet.member?(sigs, {non_bang(name_str), arity})
    end
  end

  defp non_bang(s), do: binary_part(s, 0, byte_size(s) - 1)

  defp build_diagnostic(file, name, arity, meta) do
    plain = name |> Atom.to_string() |> String.trim_trailing("!")

    Diagnostic.info("1.35",
      title: "`#{name}/#{arity}` defined without companion `#{plain}/#{arity}`",
      message:
        "Bang function `#{name}/#{arity}` exists, but the non-bang `#{plain}/#{arity}` " <>
          "does not. Elixir convention: ship both — `#{plain}/#{arity}` returns " <>
          "`{:ok, value}` / `{:error, reason}`, and `#{name}/#{arity}` is a thin " <>
          "wrapper that unwraps `:ok` and raises on `:error`.",
      why:
        "Pairing the two lets callers choose: callers that have already validated the " <>
          "input use the bang for terse code (in seeds, scripts, fixtures); callers " <>
          "handling expected failure use the non-bang and pattern-match. A lone bang " <>
          "forces all callers to either rescue/try (anti-pattern) or duplicate the " <>
          "success/failure logic. The stdlib follows this rigorously: `File.read/1` + " <>
          "`File.read!/1`, `Map.fetch/2` + `Map.fetch!/2`.",
      alternatives: [
        Fix.new(
          summary: "Ship the non-bang variant alongside the bang",
          detail:
            "@spec #{plain}(...) :: {:ok, t()} | {:error, term()}\n" <>
              "def #{plain}(args), do: # ... returns ok/error tuple\n\n" <>
              "@spec #{name}(...) :: t() | no_return()\n" <>
              "def #{name}(args) do\n" <>
              "  case #{plain}(args) do\n" <>
              "    {:ok, value} -> value\n" <>
              "    {:error, reason} -> raise \"#{name}/#{arity} failed: \#{inspect(reason)}\"\n" <>
              "  end\nend",
          applies_when:
            "When the operation has an expected-failure case callers might want to handle (most cases)."
        ),
        Fix.new(
          summary: "Or rename — drop the bang if failure is impossible",
          detail:
            "If `#{name}/#{arity}` cannot fail (e.g., it operates on already-validated input " <>
              "and never raises), drop the `!` from the name. The convention reserves `!` for " <>
              "\"may raise on failure.\"",
          applies_when:
            "When the function is infallible by construction; the `!` would mislead callers."
        )
      ],
      references: ["elixir-implementing/SKILL.md#8.1", "elixir-implementing/SKILL.md#8.4"],
      context: %{name: name, arity: arity},
      file: file,
      line: AST.line(meta)
    )
  end
end
