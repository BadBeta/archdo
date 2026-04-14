defmodule Archdo.Rules.Testing.RepoInTests do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "7.2"

  @impl true
  def description, do: "Tests should use context APIs, not direct Repo calls"

  @repo_funcs ~w(insert insert! update update! delete delete! all get get! get_by get_by! one one!)a

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) and not support_file?(file) do
      find_repo_calls(file, ast)
    else
      []
    end
  end

  defp find_repo_calls(file, ast) do
    AST.find_all(ast, fn
      {{:., _, [{:__aliases__, _, mod_parts}, func]}, _meta, _args} ->
        List.last(mod_parts) == :Repo and func in @repo_funcs

      _ ->
        false
    end)
    |> Enum.take(3)
    |> Enum.map(fn {{:., _, [{:__aliases__, _, mod_parts}, func]}, meta, _} ->
      call = "#{Enum.join(mod_parts, ".")}.#{func}"

      Diagnostic.info("7.2",
        title: "Direct Repo call in test",
        message: "#{call} is called directly from a test",
        why:
          "Tests that talk to Repo bypass the context's public API and end up testing the schema instead of " <>
            "the behaviour. They also leak knowledge of the data layer into the test (changeset rules, " <>
            "associations) so a context refactor breaks tests that have nothing to do with the change. Setting " <>
            "up state through `MyContext.create_thing(attrs)` exercises the same code path real callers use.",
        alternatives: [
          Fix.new(
            summary: "Set up state through the context's public API",
            detail:
              "Replace direct `Repo.insert!/1` calls with calls to the context's `create_*` functions (or " <>
                "ExMachina factories that wrap them). Tests now run through the same path as production code.",
            applies_when: "The context exposes a constructor for the entity being tested."
          ),
          Fix.new(
            summary: "Use a fixtures or factory module that wraps the Repo calls",
            detail:
              "If the data shape is complex and you need fine control, define an ExMachina factory or a " <>
                "fixtures module under `test/support/`. The Repo calls live in one place and the rule no longer " <>
                "fires (support files are excluded).",
            applies_when: "The setup needs more flexibility than the public API provides."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#7.2"],
        context: %{call: call},
        file: file,
        line: AST.line(meta)
      )
    end)
  end

  defp support_file?(file) do
    String.contains?(file, "/support/") or String.contains?(file, "/factory") or
      String.contains?(file, "data_case") or String.contains?(file, "conn_case") or
      String.contains?(file, "test_helper")
  end
end
