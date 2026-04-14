defmodule Archdo.Rules.Testing.LongSetup do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @max_setup_nodes 80

  @impl true
  def id, do: "7.11"

  @impl true
  def description, do: "Setup blocks > 30 lines suggest over-coupled tests"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      false -> []
      true -> find_long_setups(file, ast)
    end
  end

  defp find_long_setups(file, ast) do
    AST.find_all(ast, fn
      {:setup, _, _} -> true
      {:setup_all, _, _} -> true
      _ -> false
    end)
    |> Enum.map(fn {kind, meta, args} ->
      size = ast_size(args)

      if size > @max_setup_nodes do
        {kind, AST.line(meta), size}
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn {kind, line, size} ->
      Diagnostic.info("7.11",
        title: "Long #{kind} block",
        message: "#{kind} block has #{size} AST nodes (~#{div(size, 3)} lines)",
        why:
          "Long setup blocks indicate the tests in the file all need a lot of preconditions in place — " <>
            "usually because they're testing across too many concerns. Tests with fragile, opaque setup are " <>
            "hard to understand (you have to read setup before each test makes sense) and hard to change " <>
            "(every test depends on every preposition).",
        alternatives: [
          Fix.new(
            summary: "Extract helpers and use a factory module",
            detail:
              "Move recurring setup snippets into named functions or an ExMachina/factory module under " <>
                "test/support/. The setup block becomes a series of intent-revealing calls and the helpers can " <>
                "be reused across files.",
            applies_when: "The setup builds up domain entities that other tests also need."
          ),
          Fix.new(
            summary: "Split the test file by feature",
            detail:
              "If different tests in the same file need different parts of the setup, split the file so each " <>
                "test file only sets up what its tests need. Smaller files have smaller setup blocks.",
            applies_when: "Different tests need different subsets of the setup."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#7.11"],
        context: %{kind: kind, size: size},
        file: file,
        line: line
      )
    end)
  end

  defp ast_size(node), do: Archdo.AST.ast_size(node)
end
