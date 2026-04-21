defmodule Archdo.Rules.Testing.OverMocking do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "7.23"

  @impl true
  def description, do: "Tests with excessive mocking — 4+ expect or 3+ stub calls in a single test"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      false -> []
      true -> find_over_mocked_tests(file, ast)
    end
  end

  defp find_over_mocked_tests(file, ast) do
    ast
    |> extract_test_blocks()
    |> Enum.flat_map(fn {name, meta, body} ->
      expect_count = count_calls(body, :expect)
      stub_count = count_calls(body, :stub)

      cond do
        expect_count >= 4 ->
          [over_expect_diagnostic(file, meta, name, expect_count)]

        stub_count >= 3 ->
          [over_stub_diagnostic(file, meta, name, stub_count)]

        true ->
          []
      end
    end)
  end

  defp extract_test_blocks(ast) do
    ast
    |> AST.find_all(fn
      {:test, _meta, [_name | _]} -> true
      _ -> false
    end)
    |> Enum.map(fn {:test, meta, [name | rest]} ->
      body =
        case rest do
          [_, [do: body]] -> body
          [[do: body]] -> body
          _ -> nil
        end

      {name, meta, body}
    end)
  end

  defp count_calls(nil, _fun_name), do: 0

  defp count_calls(body, fun_name) do
    body
    |> AST.find_all(fn
      {^fun_name, _, args} when is_list(args) -> true
      {{:., _, [_, ^fun_name]}, _, _} -> true
      _ -> false
    end)
    |> length()
  end

  defp over_expect_diagnostic(file, meta, test_name, count) do
    Diagnostic.info("7.23",
      title: "Over-mocking in test",
      message:
        "Test \"#{test_name}\" has #{count} expect() calls — " <>
          "the test may be verifying mock wiring rather than real behaviour",
      why:
        "When a test sets up many expectations it becomes tightly coupled to implementation details. " <>
          "A small refactor inside the production code breaks the test even though the observable behaviour " <>
          "hasn't changed. This makes the test suite expensive to maintain and fragile under change.",
      alternatives: [
        Fix.new(
          summary: "Extract a shared setup or helper",
          detail:
            "Move repeated expectations into a `setup` block or a private helper so each test " <>
              "only declares the expectations unique to its scenario.",
          applies_when: "Multiple tests share the same base expectations."
        ),
        Fix.new(
          summary: "Test through the public API instead of mocking internals",
          detail:
            "If the module under test orchestrates several collaborators, consider testing it " <>
              "through its public interface with real (or in-memory) implementations rather than " <>
              "mocking every dependency.",
          applies_when: "The mocked modules are internal collaborators, not external services."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#7.23"],
      context: %{test_name: test_name, expect_count: count},
      file: file,
      line: AST.line(meta)
    )
  end

  defp over_stub_diagnostic(file, meta, test_name, count) do
    Diagnostic.info("7.23",
      title: "Excessive stubbing in test",
      message:
        "Test \"#{test_name}\" has #{count} stub() calls — " <>
          "consider whether the test needs so many faked dependencies",
      why:
        "Heavy stubbing often signals that the module under test has too many dependencies. " <>
          "Each stub is a seam that can drift out of sync with the real implementation. " <>
          "Fewer dependencies mean fewer stubs and more trustworthy tests.",
      alternatives: [
        Fix.new(
          summary: "Reduce the number of dependencies the module needs",
          detail:
            "If a module requires 3+ stubs to test, it may be doing too much. " <>
              "Split responsibilities so each module has fewer collaborators.",
          applies_when: "The module under test has many injected dependencies."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#7.23"],
      context: %{test_name: test_name, stub_count: count},
      file: file,
      line: AST.line(meta)
    )
  end
end
