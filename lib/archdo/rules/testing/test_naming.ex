defmodule Archdo.Rules.Testing.TestNaming do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "7.8"

  @impl true
  def description, do: "Test modules should be named *Test in *_test.exs files"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      false -> []
      true -> check_naming(file, ast)
    end
  end

  defp check_naming(file, ast) do
    if support_file?(file) do
      []
    else
      module_names = extract_module_names(ast)

      cond do
        not String.ends_with?(file, "_test.exs") ->
          []

        Enum.empty?(module_names) ->
          []

        Enum.all?(module_names, fn name -> String.ends_with?(name, "Test") end) ->
          []

        true ->
          name = hd(module_names)

          [
            Diagnostic.info("7.8",
              title: "Test module without `Test` suffix",
              message: "Test module #{name} does not end in `Test`",
              why:
                "ExUnit identifies test modules by the file suffix `_test.exs`, but humans and tooling rely " <>
                  "on the `*Test` module-name convention to grep for tests, navigate IDEs, and group reports. " <>
                  "A test module that doesn't follow the convention is invisible to the tooling everyone uses.",
              alternatives: [
                Fix.new(
                  summary: "Rename the module to end in `Test`",
                  detail:
                    "Update the `defmodule` line so the last segment ends in `Test` (e.g. " <>
                      "`MyApp.AccountsTest`). The file name should already match `*_test.exs`.",
                  applies_when: "The module is a regular ExUnit test."
                ),
                Fix.new(
                  summary: "Move the module out of test/ if it isn't a test",
                  detail:
                    "If this is a helper module that ended up under test/ by mistake, move it to " <>
                      "`test/support/` (and add `test/support` to elixirc_paths).",
                  applies_when: "The module is a helper, not a test."
                )
              ],
              references: ["ARCHITECTURE_RULES.md#7.8"],
              context: %{module: name},
              file: file,
              line: 1
            )
          ]
      end
    end
  end

  defp extract_module_names(ast) do
    {_, names} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [{:__aliases__, _, aliases} | _]} = node, acc ->
          name = AST.module_name(Module.concat(aliases))
          {node, [name | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(names)
  end

  defp support_file?(file) do
    String.contains?(file, "/support/") or
      String.ends_with?(file, "test_helper.exs") or
      String.ends_with?(file, "data_case.ex") or
      String.ends_with?(file, "conn_case.ex")
  end
end
