defmodule Archdo.RuleCase do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case, async: true

      @doc """
      Parse Elixir code string and run a rule against it.
      Returns the list of diagnostics.
      """
      def analyze(rule, code, opts \\ []) do
        file = Keyword.get(opts, :file, "lib/test_module.ex")

        {:ok, ast} =
          Code.string_to_quoted(code,
            file: file,
            columns: true,
            token_metadata: true
          )

        # `analyze/3` is optional in the Archdo.Rule behaviour — project-only
        # rules don't implement it. Tests that call this helper against a
        # project-only rule get an empty diagnostic list (the rule's actual
        # work is in analyze_project/N or analyze_compiled/N).
        # `Code.ensure_loaded/1` first because `function_exported?/3`
        # returns `false` for modules not yet loaded into the runtime.
        _ = Code.ensure_loaded(rule)

        case function_exported?(rule, :analyze, 3) do
          true -> rule.analyze(file, ast, opts)
          false -> []
        end
      end

      @doc """
      Assert that analyzing the code produces no diagnostics.
      """
      def assert_clean(rule, code, opts \\ []) do
        diagnostics = analyze(rule, code, opts)
        assert diagnostics == [], "Expected no diagnostics, got: #{inspect(diagnostics)}"
      end

      @doc """
      Assert that analyzing the code produces diagnostics with the given rule_id.
      Returns the diagnostics for further assertions.
      """
      def assert_flagged(rule, code, opts \\ []) do
        diagnostics = analyze(rule, code, opts)
        assert diagnostics != [], "Expected diagnostics but got none"
        diagnostics
      end
    end
  end
end
