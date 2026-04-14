defmodule Archdo.Rules.Testing.NoAssertion do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @assertion_macros ~w(assert refute assert_raise assert_received assert_receive
                        refute_received refute_receive assert_in_delta refute_in_delta
                        catch_throw catch_exit catch_error)a

  @impl true
  def id, do: "7.9"

  @impl true
  def description, do: "Tests must contain at least one assertion"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      false -> []
      true -> find_tests_without_assertions(file, ast)
    end
  end

  defp find_tests_without_assertions(file, ast) do
    AST.find_all(ast, fn
      # test "name" do ... end
      {:test, _meta, [_name, _body]} -> true
      # test "name", %{...} do ... end (with context)
      {:test, _meta, [_name, _ctx, _body]} -> true
      _ -> false
    end)
    |> Enum.reject(&has_assertion?/1)
    |> Enum.map(fn {_, meta, args} ->
      test_name = extract_test_name(args)

      Diagnostic.warning("7.9",
        title: "Test without assertions",
        message: "Test #{inspect(test_name)} contains no assertions",
        why:
          "A test that doesn't assert anything passes for the wrong reason: it only fails if the code under " <>
            "test raises an exception. Any silent regression — wrong return value, missing side effect — " <>
            "slips through. The test offers false confidence and shows up green in coverage reports.",
        alternatives: [
          Fix.new(
            summary: "Add an `assert`/`assert_receive`/`refute` checking the actual outcome",
            detail:
              "Identify what the test was meant to verify and add an explicit assertion. Even " <>
                "`assert {:ok, _} = ...` is enough to catch a regression that returns `:error`.",
            applies_when: "The test was supposed to verify something."
          ),
          Fix.new(
            summary: "Delete the test if it's a placeholder",
            detail:
              "If the test is empty because someone scaffolded it and never came back, delete it. A non-test " <>
                "is worse than no test because it inflates the green count.",
            applies_when: "The test was never finished."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#7.9"],
        context: %{test_name: test_name},
        file: file,
        line: AST.line(meta)
      )
    end)
  end

  defp has_assertion?({:test, _, args}) do
    body = List.last(args)

    AST.contains?(body, fn
      # Pattern-match assertion must be checked BEFORE the generic atom-macro
      # clause since {:=, _, _} would match both.
      {:=, _, [lhs, _rhs]} ->
        non_trivial_pattern?(lhs)

      {macro, _, _} when macro in @assertion_macros ->
        true

      {macro, _, _} when is_atom(macro) ->
        # Custom assertion helpers
        name = Atom.to_string(macro)

        String.starts_with?(name, "assert_") or
          String.starts_with?(name, "refute_") or
          String.starts_with?(name, "expect_") or
          name in ~w(should_match)

      _ ->
        false
    end)
  end

  # Unwrap literal_encoder blocks first
  defp non_trivial_pattern?({:__block__, _, [inner]}), do: non_trivial_pattern?(inner)
  defp non_trivial_pattern?({:{}, _, _}), do: true
  defp non_trivial_pattern?({_, _}), do: true
  defp non_trivial_pattern?({:%, _, _}), do: true
  defp non_trivial_pattern?({:%{}, _, _}), do: true
  defp non_trivial_pattern?([_ | _]), do: true
  defp non_trivial_pattern?(_), do: false

  defp extract_test_name([name | _]) when is_binary(name), do: name
  defp extract_test_name([{:__block__, _, [name]} | _]) when is_binary(name), do: name
  defp extract_test_name(_), do: "(unknown)"
end
