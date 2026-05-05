defmodule Archdo.Rules.Module.CondWithoutCatchall do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.AST.Unwrap

  @impl true
  def id, do: "6.61"

  @impl true
  def description, do: "cond without `true ->` catch-all — risks CondClauseError at runtime"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    Enum.flat_map(AST.find_all(ast, &cond_node?/1), fn {:cond, meta, args} ->
      case has_truthy_catchall?(args) do
        true -> []
        false -> [build_diagnostic(file, AST.line(meta))]
      end
    end)
  end

  defp cond_node?({:cond, _, _}), do: true
  defp cond_node?(_), do: false

  # `cond do ... end` AST: `{:cond, _, [[do: [{:->, _, [[guard], body]}, ...]]]}`.
  # Has a catch-all if any clause's guard is a literal value that's
  # truthy by Elixir's `cond` truthiness rules (anything that's neither
  # `false` nor `nil`). The most common forms are `true ->`, but
  # `:otherwise ->`, `:else ->`, etc. are also catch-alls in practice.
  defp has_truthy_catchall?(args) do
    clauses = extract_clauses(args)
    Enum.any?(clauses, &catchall_clause?/1)
  end

  # `cond do ... end` args is a single-element list whose only element
  # is a keyword list with `:do` → clauses. Tolerant of literal-encoder
  # wrapping (`{:__block__, _, [:do]}` as the key).
  defp extract_clauses([kw]) when is_list(kw) do
    case Unwrap.kw_get(kw, :do) do
      {:ok, clauses} when is_list(clauses) -> clauses
      _ -> []
    end
  end

  defp extract_clauses(_), do: []

  defp catchall_clause?({:->, _, [[guard], _body]}), do: truthy_literal?(guard)
  defp catchall_clause?(_), do: false

  # §§ elixir-implementing: §2.1 — multi-clause head dispatches on
  # literal shape rather than relying on a single conditional with
  # boolean side-effects.
  defp truthy_literal?(true), do: true
  defp truthy_literal?(false), do: false
  defp truthy_literal?(nil), do: false
  defp truthy_literal?(atom) when is_atom(atom), do: true
  defp truthy_literal?(int) when is_integer(int) and int != 0, do: true
  defp truthy_literal?(float) when is_float(float) and float != 0.0, do: true
  defp truthy_literal?(str) when is_binary(str) and byte_size(str) > 0, do: true
  defp truthy_literal?({:__block__, _, [inner]}), do: truthy_literal?(inner)
  defp truthy_literal?(_), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.warning("6.61",
      title: "cond without catch-all clause",
      message:
        "This `cond` has no `true ->` catch-all — if no condition matches at runtime, " <>
          "Elixir raises `CondClauseError`. Add an explicit final `true -> default` clause.",
      why:
        "Elixir does NOT auto-default a `cond` whose conditions all evaluate to falsy. The " <>
          "result is `(CondClauseError) no cond clause evaluated to a truthy value` — a " <>
          "runtime crash that's invisible until the unmatched-input path is exercised. The " <>
          "convention is to terminate every `cond` with `true -> default` so the structure " <>
          "is a total function over its input space.",
      alternatives: [
        Fix.new(
          summary: "Add `true -> default` as the final clause",
          detail:
            "cond do\n" <>
              "  x > 10 -> :large\n" <>
              "  x > 5 -> :medium\n" <>
              "  true -> :small  # explicit default\n" <>
              "end",
          applies_when: "Always — `cond` should be a total function."
        )
      ],
      references: ["elixir-implementing/SKILL.md#7.1"],
      context: %{},
      file: file,
      line: line
    )
  end
end
