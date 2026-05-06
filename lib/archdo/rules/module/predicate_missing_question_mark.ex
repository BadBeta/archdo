defmodule Archdo.Rules.Module.PredicateMissingQuestionMark do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.AST.Unwrap

  @impl true
  def id, do: "6.88"

  @impl true
  def description,
    do:
      "Public function returning only `true` / `false` literals — name should " <>
        "end in `?` (Elixir predicate convention)"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_predicates(file, ast)
    end
  end

  defp find_predicates(file, ast) do
    ast
    |> AST.extract_functions(:public)
    |> Enum.group_by(fn {name, arity, _, _, _} -> {name, arity} end)
    |> Enum.flat_map(fn {{name, arity}, clauses} -> maybe_flag(file, name, arity, clauses) end)
  end

  defp maybe_flag(file, name, arity, clauses) do
    case predicate_shape?(name, clauses) do
      true -> [build_diagnostic(file, name, arity, clauses)]
      false -> []
    end
  end

  defp predicate_shape?(name, clauses) do
    not predicate_named?(name) and at_least_two(clauses) and
      Enum.all?(clauses, &returns_boolean_literal?/1)
  end

  defp predicate_named?(name) do
    s = Atom.to_string(name)
    String.ends_with?(s, "?") or String.ends_with?(s, "!")
  end

  defp at_least_two([_, _ | _]), do: true
  defp at_least_two(_), do: false

  defp returns_boolean_literal?({_, _, _, _, body}) do
    case extract_body_expr(body) do
      true -> true
      false -> true
      _ -> false
    end
  end

  defp extract_body_expr(body) when is_list(body) do
    case Unwrap.kw_get(body, :do) do
      {:ok, expr} -> expr
      :error -> :__not_a_literal__
    end
  end

  defp extract_body_expr(_), do: :__not_a_literal__

  defp build_diagnostic(file, name, arity, [{_, _, meta, _, _} | _]) do
    Diagnostic.info("6.88",
      title: "`#{name}/#{arity}` returns booleans — name should end in `?`",
      message:
        "Function `#{name}/#{arity}` returns `true` / `false` from every clause but " <>
          "does not end in `?`. Elixir convention: predicate functions end in `?` " <>
          "(`valid?/1`, `empty?/1`, `admin?/1`).",
      why:
        "The trailing `?` is part of the function name and signals \"asks a yes/no " <>
          "question.\" Without it, callers can't tell at a glance whether " <>
          "`is_admin(user)` returns a boolean or perhaps an `:admin` atom / `{:ok, " <>
          "user}` tuple. Convention: bare `is_X` is reserved for **guard-safe** " <>
          "checks (matches `is_atom`, `is_integer`); for non-guard predicates use " <>
          "`x?`. Concretely: `valid?/1` not `is_valid/1`; `admin?/1` not `is_admin/1`.",
      alternatives: [
        Fix.new(
          summary: "Rename to end in `?`",
          detail:
            "# Rename and update call sites:\n" <>
              "def #{predicate_name(name)}(...), do: true\n" <>
              "def #{predicate_name(name)}(...), do: false\n\n" <>
              "# Predicates compose well in Enum / pipeline contexts:\n" <>
              "Enum.filter(users, &#{predicate_name(name)}/1)",
          applies_when:
            "Always — the convention is universal in the Elixir stdlib, ecosystem, and Credo's `PredicateName` check."
        )
      ],
      references: ["elixir-implementing/SKILL.md#8.4"],
      context: %{name: name, arity: arity},
      file: file,
      line: AST.line(meta)
    )
  end

  defp predicate_name(name) do
    s = Atom.to_string(name)

    case s do
      "is_" <> rest -> rest <> "?"
      "has_" <> _ -> s <> "?"
      _ -> s <> "?"
    end
  end
end
