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

        rule.analyze(file, ast, opts)
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
