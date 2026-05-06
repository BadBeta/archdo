defmodule Archdo.Rules.Testing.EqualsCompareTaggedTupleInTest do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "7.32"

  @impl true
  def description,
    do:
      "Test asserts `{:ok, _}`/`{:error, _}` with `==` instead of pattern match — " <>
        "pattern match yields better failure diffs and binds variables"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      false -> []
      true -> find_eq_compare_tagged_tuple(file, ast)
    end
  end

  defp find_eq_compare_tagged_tuple(file, ast) do
    ast
    |> AST.find_all(&assert_eq_tagged_tuple?/1)
    |> Enum.map(fn {_, meta, _} -> build_diagnostic(file, AST.line(meta)) end)
  end

  # `assert {:ok, ...} == <call>` parses as
  # `{:assert, _, [{:==, _, [{:{}, _, [...]}, rhs]}]}` for tuples of
  # arity != 2, but as `{:assert, _, [{:==, _, [{:ok, _}, rhs]}]}` for
  # 2-tuples.  We also accept `{:error, _}` and `:ok`/`:error` 2-tuples.
  defp assert_eq_tagged_tuple?({:assert, _, [{:==, _, [lhs, _rhs]}]}),
    do: tagged_tuple_literal?(lhs)

  defp assert_eq_tagged_tuple?(_), do: false

  defp tagged_tuple_literal?({tag, _value}) when tag in [:ok, :error], do: true

  defp tagged_tuple_literal?({:{}, _, [tag | _rest]})
       when tag in [:ok, :error],
       do: true

  defp tagged_tuple_literal?(_), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.info("7.32",
      title: "`assert {:ok/:error, ...} == call` — prefer pattern match",
      message:
        "Test asserts a tagged-tuple shape with `==`. Pattern matching " <>
          "(`assert {:ok, %User{}} = call`) gives much better failure diffs and binds " <>
          "the inner value for further assertions in the same test.",
      why:
        "On `==` failure, ExUnit prints `Assertion with == failed: lhs: ..., rhs: ...` " <>
          "but the diff is line-based and doesn't highlight which field of the inner " <>
          "struct or map is wrong. Pattern match (`=`) does a structural assertion: " <>
          "ExUnit reports exactly the sub-pattern that failed and you can bind names " <>
          "(`assert {:ok, %User{id: id}} = ...`) to use in subsequent assertions. It " <>
          "also future-proofs the test against benign additions like new struct fields.",
      alternatives: [
        Fix.new(
          summary: "Pattern-match the tagged tuple",
          detail:
            "# Strict (whole tuple, fails on any extra field):\n" <>
              "assert {:ok, %User{email: \"a@b.com\"}} = Accounts.create_user(attrs)\n\n" <>
              "# Permissive on inner shape, then deeper asserts:\n" <>
              "assert {:ok, %User{} = user} = Accounts.create_user(attrs)\n" <>
              "assert user.email == \"a@b.com\"\n" <>
              "assert is_binary(user.id)",
          applies_when: "When asserting the result of a function returning ok/error tuples."
        )
      ],
      references: ["elixir-implementing/SKILL.md#4.2", "elixir-implementing/SKILL.md#7.10"],
      context: %{},
      file: file,
      line: line
    )
  end
end
