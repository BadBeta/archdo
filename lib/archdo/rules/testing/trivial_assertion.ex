defmodule Archdo.Rules.Testing.TrivialAssertion do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "7.10"

  @impl true
  def description, do: "Tests with trivial assertions like assert true, assert 1 == 1"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      false -> []
      true -> find_trivial_assertions(file, ast)
    end
  end

  defp find_trivial_assertions(file, ast) do
    AST.find_all(ast, fn
      # assert true
      {:assert, _, [true]} -> true
      {:assert, _, [{:__block__, _, [true]}]} -> true
      # assert false (should be refute false)
      {:assert, _, [false]} -> true
      # assert x == x (where both sides are the same)
      {:assert, _, [{:==, _, [a, a]}]} -> true
      # assert 1 == 1
      {:assert, _, [{:==, _, [{:__block__, _, [n]}, {:__block__, _, [n]}]}]} when is_integer(n) -> true
      _ -> false
    end)
    |> Enum.map(fn {:assert, meta, _} ->
      Diagnostic.warning("7.10",
        title: "Trivial assertion in test",
        message: "Test contains a tautology like `assert true`, `assert false`, or `assert x == x`",
        why:
          "Tautological assertions never test anything: `assert true` always passes, `assert false` always " <>
            "fails (and breaks CI for nothing), and `assert x == x` is a typo waiting to happen. They are the " <>
            "telltale signs of a placeholder test that was never finished or a copy-paste that was never edited.",
        alternatives: [
          Fix.new(
            summary: "Replace with a real assertion that exercises the code under test",
            detail:
              "Identify what the test was meant to verify and write the assertion against an actual call's " <>
                "result. If the original intent is unclear, ask the author or look at the surrounding tests.",
            applies_when: "The test was meant to verify something specific."
          ),
          Fix.new(
            summary: "Delete the test if it's truly placeholder",
            detail:
              "An empty placeholder is worse than no test — it inflates the green count and obscures real " <>
                "coverage gaps. Delete it and note the missing coverage in a TODO if needed.",
            applies_when: "The test was scaffolding never filled in."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#7.10"],
        context: %{},
        file: file,
        line: AST.line(meta)
      )
    end)
  end
end
