defmodule Archdo.Rules.Module.RegexInLoopTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.RegexInLoop

  describe "analyze/3" do
    test "flags ~r inside Enum.map callback" do
      code = ~S"""
      defmodule MyApp.Parser do
        def parse(lines) do
          Enum.map(lines, fn line ->
            Regex.match?(~r/^\d+/, line)
          end)
        end
      end
      """

      diags = assert_flagged(RegexInLoop, code)
      diag = hd(diags)
      assert diag.rule_id == "6.49"
      assert diag.severity == :info
    end

    test "flags ~r inside Enum.filter callback" do
      code = ~S"""
      defmodule MyApp.Filter do
        def filter_emails(strings) do
          Enum.filter(strings, fn s ->
            Regex.match?(~r/@/, s)
          end)
        end
      end
      """

      diags = assert_flagged(RegexInLoop, code)
      assert hd(diags).rule_id == "6.49"
    end

    test "flags ~r inside handle_info callback" do
      code = ~S"""
      defmodule MyApp.Worker do
        use GenServer

        def handle_info({:data, payload}, state) do
          case Regex.run(~r/error: (.+)/, payload) do
            [_, msg] -> {:noreply, %{state | last_error: msg}}
            nil -> {:noreply, state}
          end
        end
      end
      """

      diags = assert_flagged(RegexInLoop, code)
      assert hd(diags).rule_id == "6.49"
    end

    test "allows ~r in module attribute" do
      code = ~S"""
      defmodule MyApp.Parser do
        @pattern ~r/^\d+/

        def parse(lines) do
          Enum.map(lines, fn line ->
            Regex.match?(@pattern, line)
          end)
        end
      end
      """

      assert_clean(RegexInLoop, code)
    end

    test "allows code without regex in loops" do
      code = ~S"""
      defmodule MyApp.Processor do
        def process(items) do
          Enum.map(items, fn item ->
            String.upcase(item)
          end)
        end
      end
      """

      assert_clean(RegexInLoop, code)
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.ParserTest do
        def parse(lines) do
          Enum.map(lines, fn line ->
            Regex.match?(~r/^\d+/, line)
          end)
        end
      end
      """

      assert analyze(RegexInLoop, code, file: "test/parser_test.exs") == []
    end
  end
end
